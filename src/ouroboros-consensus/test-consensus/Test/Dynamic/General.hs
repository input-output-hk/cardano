{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE UndecidableInstances  #-}

module Test.Dynamic.General (
    prop_simple_protocol_convergence
  ) where

import           Data.Map.Strict (Map)
import           Data.Typeable (Typeable)
import           Test.QuickCheck

import           Control.Monad.Class.MonadAsync
import           Control.Monad.Class.MonadFork (MonadFork)
import           Control.Monad.Class.MonadSay
import           Control.Monad.Class.MonadST
import           Control.Monad.Class.MonadSTM
import           Control.Monad.Class.MonadThrow
import           Control.Monad.Class.MonadTime
import           Control.Monad.Class.MonadTimer
import           Control.Monad.IOSim (runSimOrThrow)

import           Ouroboros.Network.MockChain.Chain

import           Ouroboros.Consensus.BlockchainTime
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Ledger.Mock
import           Ouroboros.Consensus.Node.ProtocolInfo
import           Ouroboros.Consensus.Node.Run
import           Ouroboros.Consensus.NodeId
import           Ouroboros.Consensus.Protocol (NodeConfig)
import           Ouroboros.Consensus.Util.Condense
import           Ouroboros.Consensus.Util.Orphans ()
import           Ouroboros.Consensus.Util.Random
import           Ouroboros.Consensus.Util.ThreadRegistry

import           Test.Dynamic.Network

prop_simple_protocol_convergence :: forall c ext.
                                   ( RunNode (SimpleBlock c ext)
                                   , SimpleCrypto c
                                   , Show ext
                                   , Condense ext
                                   , Typeable ext
                                   )
                                 => (CoreNodeId -> ProtocolInfo (SimpleBlock c ext))
                                 -> (   [NodeId]
                                     -> Map NodeId ( NodeConfig (BlockProtocol (SimpleBlock c ext))
                                                   , Chain (SimpleBlock c ext)
                                                   )
                                     -> Property)
                                 -> NumCoreNodes
                                 -> NumSlots
                                 -> Seed
                                 -> Property
prop_simple_protocol_convergence pInfo isValid numCoreNodes numSlots seed =
    runSimOrThrow $
      test_simple_protocol_convergence pInfo isValid numCoreNodes numSlots seed

-- Run protocol on the broadcast network, and check resulting chains on all nodes.
test_simple_protocol_convergence :: forall m c ext.
                                    ( MonadAsync m
                                    , MonadFork  m
                                    , MonadMask  m
                                    , MonadSay   m
                                    , MonadST    m
                                    , MonadTime  m
                                    , MonadTimer m
                                    , MonadThrow (STM m)
                                    , RunNode (SimpleBlock c ext)
                                    , SimpleCrypto c
                                    , Show ext
                                    , Condense ext
                                    , Typeable ext
                                    )
                                 => (CoreNodeId -> ProtocolInfo (SimpleBlock c ext))
                                 -> (   [NodeId]
                                     -> Map NodeId ( NodeConfig (BlockProtocol (SimpleBlock c ext))
                                                   , Chain (SimpleBlock c ext)
                                                   )
                                     -> Property)
                                 -> NumCoreNodes
                                 -> NumSlots
                                 -> Seed
                                 -> m Property
test_simple_protocol_convergence pInfo isValid numCoreNodes numSlots seed =
    fmap (isValid nodeIds) $ withThreadRegistry $ \registry -> do
      btime <- testBlockchainTime registry numSlots slotLen
      broadcastNetwork registry
                       btime
                       numCoreNodes
                       pInfo
                       (seedToChaCha seed)
                       numSlots
                       slotLen
  where
    nodeIds :: [NodeId]
    nodeIds = map fromCoreNodeId $ enumCoreNodes numCoreNodes

    slotLen :: DiffTime
    slotLen = 100000
