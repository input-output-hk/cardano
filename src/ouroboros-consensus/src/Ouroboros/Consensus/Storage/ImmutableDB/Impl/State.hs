{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE DeriveAnyClass            #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE NamedFieldPuns            #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}
module Ouroboros.Consensus.Storage.ImmutableDB.Impl.State
  ( -- * State types
    ImmutableDBEnv (..)
  , InternalState (..)
  , dbIsOpen
  , OpenState (..)
    -- * State helpers
  , mkOpenState
  , getOpenState
  , modifyOpenState
  , withOpenState
  , closeOpenHandles
  , cleanUp
  ) where

import           Control.Monad.State.Strict
import           Control.Tracer (Tracer)
import           GHC.Generics (Generic)
import           GHC.Stack (HasCallStack)

import           Cardano.Prelude (NoUnexpectedThunks (..))

import           Ouroboros.Consensus.BlockchainTime (BlockchainTime)
import           Ouroboros.Consensus.Util (SomePair (..))
import           Ouroboros.Consensus.Util.IOLike
import           Ouroboros.Consensus.Util.ResourceRegistry (ResourceRegistry,
                     allocate)

import           Ouroboros.Consensus.Storage.FS.API
import           Ouroboros.Consensus.Storage.FS.API.Types

import           Ouroboros.Consensus.Storage.ImmutableDB.Chunks
import           Ouroboros.Consensus.Storage.ImmutableDB.Impl.Index (Index)
import qualified Ouroboros.Consensus.Storage.ImmutableDB.Impl.Index as Index
import           Ouroboros.Consensus.Storage.ImmutableDB.Impl.Index.Primary
                     (SecondaryOffset)
import           Ouroboros.Consensus.Storage.ImmutableDB.Impl.Index.Secondary
                     (BlockOffset (..))
import           Ouroboros.Consensus.Storage.ImmutableDB.Impl.Util
import           Ouroboros.Consensus.Storage.ImmutableDB.Parser (BlockSummary)
import           Ouroboros.Consensus.Storage.ImmutableDB.Types

{------------------------------------------------------------------------------
  Main types
------------------------------------------------------------------------------}

-- | The environment used by the immutable database.
data ImmutableDBEnv m hash = forall h e. ImmutableDBEnv
    { hasFS            :: !(HasFS m h)
    , varInternalState :: !(StrictMVar m (InternalState m hash h))
    , chunkFileParser  :: !(ChunkFileParser e m (BlockSummary hash) hash)
    , chunkInfo        :: !ChunkInfo
    , hashInfo         :: !(HashInfo hash)
    , tracer           :: !(Tracer m (TraceEvent e hash))
    , registry         :: !(ResourceRegistry m)
    , cacheConfig      :: !Index.CacheConfig
    , blockchainTime   :: !(BlockchainTime m)
    }

data InternalState m hash h =
    DbClosed
  | DbOpen !(OpenState m hash h)
  deriving (Generic, NoUnexpectedThunks)

dbIsOpen :: InternalState m hash h -> Bool
dbIsOpen DbClosed   = False
dbIsOpen (DbOpen _) = True

-- | Internal state when the database is open.
data OpenState m hash h = OpenState
    { currentChunk           :: !ChunkNo
      -- ^ The current 'ChunkNo' the immutable store is writing to.
    , currentChunkOffset     :: !BlockOffset
      -- ^ The offset at which the next block will be written in the current
      -- chunk file.
    , currentSecondaryOffset :: !SecondaryOffset
      -- ^ The offset at which the next index entry will be written in the
      -- current secondary index.
    , currentChunkHandle     :: !(Handle h)
      -- ^ The write handle for the current chunk file.
    , currentPrimaryHandle   :: !(Handle h)
      -- ^ The write handle for the current primary index file.
    , currentSecondaryHandle :: !(Handle h)
      -- ^ The write handle for the current secondary index file.
    , currentTip             :: !(ImmTipWithInfo hash)
      -- ^ The current tip of the database.
    , currentIndex           :: !(Index m hash h)
      -- ^ An abstraction layer on top of the indices to allow for caching.
    }
  deriving (Generic, NoUnexpectedThunks)

{------------------------------------------------------------------------------
  State helpers
------------------------------------------------------------------------------}

-- | Create the internal open state for the given chunk.
mkOpenState
  :: forall m hash h. (HasCallStack, IOLike m)
  => ResourceRegistry m
  -> HasFS m h
  -> Index m hash h
  -> ChunkNo
  -> ImmTipWithInfo hash
  -> AllowExisting
  -> m (OpenState m hash h)
mkOpenState registry HasFS{..} index chunk tip existing = do
    eHnd <- allocateHandle $ hOpen (renderFile "epoch"     chunk) appendMode
    pHnd <- allocateHandle $ Index.openPrimaryIndex index  chunk  existing
    sHnd <- allocateHandle $ hOpen (renderFile "secondary" chunk) appendMode
    chunkOffset     <- hGetSize eHnd
    secondaryOffset <- hGetSize sHnd
    return OpenState
      { currentChunk           = chunk
      , currentChunkOffset     = BlockOffset chunkOffset
      , currentSecondaryOffset = fromIntegral secondaryOffset
      , currentChunkHandle     = eHnd
      , currentPrimaryHandle   = pHnd
      , currentSecondaryHandle = sHnd
      , currentTip             = tip
      , currentIndex           = index
      }
  where
    appendMode = AppendMode existing

    allocateHandle :: m (Handle h) -> m (Handle h)
    allocateHandle open = snd <$> allocate registry (const open) hClose

-- | Get the 'OpenState' of the given database, throw a 'ClosedDBError' in
-- case it is closed.
--
-- NOTE: Since the 'OpenState' is parameterized over a type parameter @h@ of
-- handles, which is not visible from the type of the @ImmutableDBEnv@,
-- we return a @SomePair@ here that returns the open state along with a 'HasFS'
-- instance for the /same/ type parameter @h@. Note that it would be impossible
-- to use an existing 'HasFS' instance already in scope otherwise, since the
-- @h@ parameters would not be known to match.
getOpenState :: (HasCallStack, IOLike m)
             => ImmutableDBEnv m hash
             -> m (SomePair (HasFS m) (OpenState m hash))
getOpenState ImmutableDBEnv {..} = do
    internalState <- readMVar varInternalState
    case internalState of
       DbClosed         -> throwUserError  ClosedDBError
       DbOpen openState -> return (SomePair hasFS openState)

-- | Modify the internal state of an open database.
--
-- In case the database is closed, a 'ClosedDBError' is thrown.
--
-- In case an 'UnexpectedError' is thrown, the database is closed to prevent
-- further appending to a database in a potentially inconsistent state.
--
-- __Note__: This /takes/ the 'TMVar', /then/ runs the action (which might be
-- in 'IO'), and then puts the 'TMVar' back, just like
-- 'Control.Concurrent.MVar.modifyMVar' does. Consequently, it has the same
-- gotchas that @modifyMVar@ does; the effects are observable and it is
-- susceptible to deadlock.
modifyOpenState :: forall m hash r. (HasCallStack, IOLike m)
                => ImmutableDBEnv m hash
                -> (forall h. HasFS m h -> StateT (OpenState m hash h) m r)
                -> m r
modifyOpenState ImmutableDBEnv { hasFS = hasFS :: HasFS m h, .. } action = do
    (mr, ()) <- generalBracket open close (tryImmDB . mutation)
    case mr of
      Left  e      -> throwM e
      Right (r, _) -> return r
  where
    HasFS{..}         = hasFS

    -- We use @m (Either e a)@ instead of @EitherT e m a@ for 'generalBracket'
    -- so that 'close' knows which error is thrown (@Either e (s, r)@ vs. @(s,
    -- r)@).

    open :: m (OpenState m hash h)
    -- TODO Is uninterruptibleMask_ absolutely necessary here?
    open = uninterruptibleMask_ $ takeMVar varInternalState >>= \case
      DbOpen ost -> return ost
      DbClosed   -> do
        putMVar varInternalState DbClosed
        throwUserError ClosedDBError

    close :: OpenState m hash h
          -> ExitCase (Either ImmutableDBError (r, OpenState m hash h))
          -> m ()
    close !ost ec = do
        -- It is crucial to replace the MVar.
        putMVar varInternalState st'
        followUp
      where
        (st', followUp) = case ec of
          -- If we were interrupted, restore the original state.
          ExitCaseAbort                               -> (DbOpen ost, return ())
          ExitCaseException _ex                       -> (DbOpen ost, return ())
          -- In case of success, update to the newest state
          ExitCaseSuccess (Right (_, ost'))           -> (DbOpen ost', return ())
          -- In case of an unexpected error (not an exception), close the DB
          -- for safety
          ExitCaseSuccess (Left (UnexpectedError {})) -> (DbClosed, cleanUp hasFS ost)
          -- In case a user error, just restore the previous state
          ExitCaseSuccess (Left (UserError {}))       -> (DbOpen ost, return ())

    mutation :: OpenState m hash h -> m (r, OpenState m hash h)
    mutation = runStateT (action hasFS)

-- | Perform an action that accesses the internal state of an open database.
--
-- In case the database is closed, a 'ClosedDBError' is thrown.
--
-- In case an 'UnexpectedError' is thrown while the action is being run, the
-- database is closed to prevent further appending to a database in a
-- potentially inconsistent state.
withOpenState :: forall m hash r. (HasCallStack, IOLike m)
              => ImmutableDBEnv m hash
              -> (forall h. HasFS m h -> OpenState m hash h -> m r)
              -> m r
withOpenState ImmutableDBEnv { hasFS = hasFS :: HasFS m h, .. } action = do
    (mr, ()) <- generalBracket open (const close) (tryImmDB . access)
    case mr of
      Left  e -> throwM e
      Right r -> return r
  where
    HasFS{..} = hasFS

    open :: m (OpenState m hash h)
    open = readMVar varInternalState >>= \case
      DbOpen ost -> return ost
      DbClosed   -> throwUserError ClosedDBError

    -- close doesn't take the state that @open@ returned, because the state
    -- may have been updated by someone else since we got it (remember we're
    -- using 'readMVar' here, 'takeMVar'). So we need to get the most recent
    -- state anyway.
    close :: ExitCase (Either ImmutableDBError r)
          -> m ()
    close ec = case ec of
      ExitCaseAbort                               -> return ()
      ExitCaseException _ex                       -> return ()
      ExitCaseSuccess (Right _)                   -> return ()
      -- In case of an ImmutableDBError, close when unexpected
      ExitCaseSuccess (Left (UnexpectedError {})) -> shutDown
      ExitCaseSuccess (Left (UserError {}))       -> return ()

    shutDown :: m ()
    shutDown = swapMVar varInternalState DbClosed >>= \case
      DbOpen ost -> cleanUp hasFS ost
      DbClosed   -> return ()

    access :: OpenState m hash h -> m r
    access = action hasFS

-- | Close the handles in the 'OpenState'.
--
-- Idempotent, as closing a handle is idempotent.
closeOpenHandles :: Monad m => HasFS m h -> OpenState m hash h -> m ()
closeOpenHandles HasFS { hClose } OpenState {..}  = do
    -- If one of the 'hClose' calls fails, the error will bubble up to the
    -- bracketed call to 'withRegistry', which will close the
    -- 'ResourceRegistry' and thus all the remaining handles in it.
    hClose currentChunkHandle
    hClose currentPrimaryHandle
    hClose currentSecondaryHandle

-- | Clean up the 'OpenState': 'closeOpenHandles' + close the index (i.e.,
-- shut down its background thread)
cleanUp :: Monad m => HasFS m h -> OpenState m hash h -> m ()
cleanUp hasFS ost@OpenState {..}  = do
    Index.close currentIndex
    closeOpenHandles hasFS ost
