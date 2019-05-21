{-# LANGUAGE LambdaCase #-}
module Ouroboros.Storage.IO (
      FHandle --opaque
    , open
    , truncate
    , seek
    , read
    , write
    , close
    , getSize
    ) where

import           Prelude hiding (read, truncate)

import           Control.Monad (void)
import           Data.ByteString (ByteString)
import           Data.ByteString.Internal as Internal
import           Data.Int (Int64)
import           Data.Word (Word32, Word64, Word8)
import           Foreign (Ptr)
import           System.IO (IOMode (..), SeekMode (..))
import           System.Posix (Fd)
import qualified System.Posix as Posix

import           Ouroboros.Storage.FS.Handle

type FHandle = HandleOS Fd

-- | Some sensible defaults for the 'OpenFileFlags'.
--
-- NOTE: the 'unix' package /already/ exports a smart constructor called
-- @defaultFileFlags@ already, but we define our own to not be depedent by
-- whichever default choice unix's library authors made, and to be able to
-- change our minds later if necessary. In particular, we are interested in the
-- 'append' and 'exclusive' flags, which were largely the reason why we
-- introduced this low-level module.
defaultFileFlags :: Posix.OpenFileFlags
defaultFileFlags = Posix.OpenFileFlags {
      Posix.append    = False
    , Posix.exclusive = False
    , Posix.noctty    = False
    , Posix.nonBlock  = False
    , Posix.trunc     = False
    }

-- | Opens a file from disk.
open :: FilePath -> IOMode -> IO Fd
open fp ioMode =
  Posix.openFd fp openMode fileMode fileFlags
  where
    (openMode, fileMode, fileFlags)
      | ioMode == ReadMode   = ( Posix.ReadOnly
                               , Nothing
                               , defaultFileFlags
                               )
      | ioMode == AppendMode = ( Posix.WriteOnly
                               , Just Posix.stdFileMode
                               , defaultFileFlags { Posix.append = True }
                               )
      | otherwise            = ( Posix.ReadWrite
                               , Just Posix.stdFileMode
                               , defaultFileFlags
                               )

-- | Writes the data pointed by the input 'Ptr Word8' into the input 'FHandle'.
write :: FHandle -> Ptr Word8 -> Int64 -> IO Word32
write h data' bytes = withOpenHandle "write" h $ \fd ->
    fromIntegral <$> Posix.fdWriteBuf fd data' (fromIntegral bytes)

-- | Seek within the file.
--
-- The offset may be negative.
--
-- We don't return the new offset since the behaviour of lseek is rather odd
-- (e.g., the file pointer may not actually be moved until a subsequent write)
seek :: FHandle -> SeekMode -> Int64 -> IO ()
seek h seekMode offset = withOpenHandle "seek" h $ \fd ->
    void $ Posix.fdSeek fd seekMode (fromIntegral offset)

-- | Reads a given number of bytes from the input 'FHandle'.
read :: FHandle -> Int -> IO ByteString
read h bytes = withOpenHandle "read" h $ \fd ->
    Internal.createUptoN bytes $ \ptr ->
      fromIntegral <$> Posix.fdReadBuf fd ptr (fromIntegral bytes)

-- | Truncates the file managed by the input 'FHandle' to the input size.
truncate :: FHandle -> Word64 -> IO ()
truncate h sz = withOpenHandle "truncate" h $ \fd ->
    Posix.setFdSize fd (fromIntegral sz)

-- | Close handle
--
-- This is a no-op when the handle is already closed.
close :: FHandle -> IO ()
close h = closeHandleOS h Posix.closeFd

-- | File size of the given file pointer
--
-- NOTE: This is not thread safe (changes made to the file in other threads
-- may affect this thread).
getSize :: FHandle -> IO Word64
getSize h = withOpenHandle "getSize" h $ \fd ->
     fromIntegral . Posix.fileSize <$> Posix.getFdStatus fd
