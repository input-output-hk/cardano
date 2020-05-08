{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}

module Cardano.Api.TxSubmitChairman
  ( submitTx
  ) where

import           Cardano.Prelude

import           Control.Tracer

import           Ouroboros.Consensus.Config (TopLevelConfig (..), configCodec)
import           Ouroboros.Consensus.Network.NodeToClient
import           Ouroboros.Consensus.Node.NetworkProtocolVersion
                  (nodeToClientProtocolVersion, supportedNodeToClientVersions)
import           Ouroboros.Consensus.Node.Run
import           Ouroboros.Consensus.Shelley.Protocol (TPraosStandardCrypto)
import           Ouroboros.Consensus.Shelley.Ledger (GenTx, ShelleyBlock)
import           Ouroboros.Network.Driver (runPeer)
import           Ouroboros.Network.Mux
import           Ouroboros.Network.NodeToClient hiding (NodeToClientVersion (..))
import qualified Ouroboros.Network.NodeToClient as NtC
import qualified Ouroboros.Network.Protocol.LocalTxSubmission.Client as LocalTxSub

import           Cardano.Config.Types (SocketPath(..))

submitTx
  :: Tracer IO Text
  -> IOManager
  -> TopLevelConfig (ShelleyBlock TPraosStandardCrypto)
  -> SocketPath
  -> GenTx (ShelleyBlock TPraosStandardCrypto)
  -> IO ()
submitTx
  tracer
  iomgr
  cfg
  (SocketPath path)
  genTx =
      connectTo
        (localSnocket iomgr path)
        NetworkConnectTracers {
            nctMuxTracer       = nullTracer,
            nctHandshakeTracer = nullTracer
            }
        (localInitiatorNetworkApplication proxy tracer cfg genTx)
        path
        --`catch` handleMuxError tracer chainsVar socketPath
  where
   proxy :: Proxy (ShelleyBlock TPraosStandardCrypto)
   proxy = Proxy

localInitiatorNetworkApplication
  :: Proxy (ShelleyBlock TPraosStandardCrypto)
  -> Tracer IO Text
  -- ^ tracer which logs all local tx submission protocol messages send and
  -- received by the client (see 'Ouroboros.Network.Protocol.LocalTxSubmission.Type'
  -- in 'ouroboros-network' package).
  -> TopLevelConfig (ShelleyBlock TPraosStandardCrypto)
  -> GenTx (ShelleyBlock TPraosStandardCrypto)
  -> Versions NtC.NodeToClientVersion DictVersion
              (LocalConnectionId -> OuroborosApplication 'InitiatorApp LByteString IO () Void)
localInitiatorNetworkApplication proxy tracer' cfg genTx =
    foldMapVersions
      (\v ->
        NtC.versionedNodeToClientProtocols
          (nodeToClientProtocolVersion proxy v)
          versionData
          (protocols v tracer' genTx))
      (supportedNodeToClientVersions proxy)
  where
    versionData = NodeToClientVersionData (nodeNetworkMagic proxy cfg)

    protocols clientVersion tracer tx =
        NodeToClientProtocols {
          localChainSyncProtocol =
            InitiatorProtocolOnly $
              MuxPeer
                nullTracer
                cChainSyncCodec
                chainSyncPeerNull

        , localTxSubmissionProtocol =
            InitiatorProtocolOnly $
              MuxPeerRaw $ \channel -> do
                traceWith tracer "Submitting transaction"
                result <- runPeer
                            nullTracer -- (contramap show tracer)
                            cTxSubmissionCodec
                            channel
                            (LocalTxSub.localTxSubmissionClientPeer
                               (txSubmissionClientSingle tx))
                case result of
                  Nothing  -> traceWith tracer "Transaction accepted"
                  Just msg -> traceWith tracer $ "Transaction rejected: " <> show msg

        , localStateQueryProtocol =
            InitiatorProtocolOnly $
              MuxPeer
                nullTracer
                cStateQueryCodec
                localStateQueryPeerNull
        }
      where
        Codecs
          { cChainSyncCodec
          , cTxSubmissionCodec
          , cStateQueryCodec
          } = defaultCodecs (configCodec cfg) clientVersion

txSubmissionClientSingle
  :: forall tx reject m.
     Applicative m
  => tx
  -> LocalTxSub.LocalTxSubmissionClient tx reject m (Maybe reject)
txSubmissionClientSingle tx = LocalTxSub.LocalTxSubmissionClient $ do
    pure $ LocalTxSub.SendMsgSubmitTx tx $ \mreject ->
      pure (LocalTxSub.SendMsgDone mreject)
