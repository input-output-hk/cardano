{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}

module Ouroboros.Consensus.Mock.Ledger.Forge (forgeSimple) where

import           Codec.Serialise (Serialise (..), serialise)
import           Crypto.Random (MonadRandom)
import qualified Data.ByteString.Lazy as Lazy
import           Data.Typeable (Typeable)
import           Data.Word

import           Cardano.Crypto.Hash

import           Ouroboros.Network.Block (BlockNo, SlotNo)

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Config
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Ledger.Extended
import           Ouroboros.Consensus.Mock.Ledger.Block
import           Ouroboros.Consensus.Mock.Node.Abstract
import           Ouroboros.Consensus.Node.State
import           Ouroboros.Consensus.Protocol.Abstract

forgeSimple :: forall p c m ext.
               ( MonadRandom m
               , SimpleCrypto c
               , RunMockBlock c ext
               , BlockSupportsProtocol (SimpleBlock c ext)
               , Typeable ext
               , p ~ BlockProtocol (SimpleBlock c ext)
               )
            => TopLevelConfig (SimpleBlock c ext)
            -> Update m (NodeState (SimpleBlock c ext))
            -> SlotNo                              -- ^ Current slot
            -> BlockNo                             -- ^ Current block number
            -> ExtLedgerState (SimpleBlock c ext)  -- ^ Current ledger
            -> [GenTx (SimpleBlock c ext)]         -- ^ Txs to add in the block
            -> IsLeader p                          -- ^ Proof we are slot leader
            -> m (SimpleBlock c ext)
forgeSimple cfg updateState curSlot curBlock extLedger txs proof = do
    forgeExt cfg updateState proof $ SimpleBlock {
        simpleHeader = mkSimpleHeader encode stdHeader ()
      , simpleBody   = body
      }
  where
    body :: SimpleBody
    body = SimpleBody { simpleTxs = map simpleGenTx txs }

    stdHeader :: SimpleStdHeader c ext
    stdHeader = SimpleStdHeader {
          simplePrev      = ledgerTipHash (ledgerState extLedger)
        , simpleSlotNo    = curSlot
        , simpleBlockNo   = curBlock
        , simpleBodyHash  = hash body
        , simpleBlockSize = bodySize
        }

    -- We use the size of the body, not of the whole block (= header + body),
    -- since the header size is fixed and this size is only used for
    -- prioritisation.
    bodySize :: Word64
    bodySize = fromIntegral $ Lazy.length $ serialise body
