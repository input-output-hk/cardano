{-# LANGUAGE TypeFamilies #-}

module Cardano.CLI.Shelley.Run.Query
  ( runQueryCmd
  ) where

import           Cardano.Prelude

import           Cardano.Api
                   (Address, Network(..), queryFilteredUTxOFromLocalState,
                    queryPParamsFromLocalState)

import           Cardano.CLI.Ops (CliError (..), getLocalTip)
import           Cardano.CLI.Shelley.Parsers (OutputFile (..), QueryCmd (..))

import           Cardano.Config.Protocol (mkConsensusProtocol)
import           Cardano.Config.Types (SocketPath, ConfigYamlFilePath,
                     NodeConfiguration (..),
                     SomeConsensusProtocol (..), parseNodeConfigurationFP)

import           Control.Monad.Trans.Except (ExceptT)
import           Control.Monad.Trans.Except.Extra (firstExceptT, handleIOExceptT, left)

import           Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Set as Set

import           Ouroboros.Consensus.Cardano (Protocol (..), protocolInfo)
import           Ouroboros.Consensus.Config (configCodec)
import           Ouroboros.Consensus.Node.ProtocolInfo (ProtocolInfo(..))
import           Ouroboros.Consensus.Node.Run (nodeNetworkMagic)
import           Ouroboros.Network.NodeToClient (withIOManager)

import           Ouroboros.Network.Block (getTipPoint)

import           Shelley.Spec.Ledger.PParams (PParams)


runQueryCmd :: QueryCmd -> ExceptT CliError IO ()
runQueryCmd (QueryProtocolParameters configFp sockPath outFile) =
  runQueryProtocolParameters configFp sockPath outFile
runQueryCmd (QueryFilteredUTxO addr configFp sockPath outFile) =
  runQueryFilteredUTxO addr configFp sockPath outFile
runQueryCmd cmd = liftIO $ putStrLn $ "runQueryCmd: " ++ show cmd

runQueryProtocolParameters
  :: ConfigYamlFilePath
  -> SocketPath
  -> OutputFile
  -> ExceptT CliError IO ()
runQueryProtocolParameters configFp sockPath (OutputFile outFile) = do
    nc <- liftIO $ parseNodeConfigurationFP configFp
    SomeConsensusProtocol p <- firstExceptT ProtocolError $ mkConsensusProtocol nc Nothing
    case p of
      ptcl@ProtocolRealTPraos{} -> do
        tip <- liftIO $ withIOManager $ \iomgr -> getLocalTip iomgr cfg nm sockPath
        pparams <- firstExceptT NodeLocalStateQueryError $
          queryPParamsFromLocalState cfg nm sockPath (getTipPoint tip)
        writeProtocolParameters outFile pparams
        where
          cfg = configCodec ptclcfg
          --FIXME: this works, but we should get the magic properly:
          nm  = Testnet (nodeNetworkMagic (Proxy :: Proxy blk) ptclcfg)
          ProtocolInfo{pInfoConfig = ptclcfg} = protocolInfo ptcl

      _ -> left $ IncorrectProtocolSpecifiedError (ncProtocol nc)

runQueryFilteredUTxO
  :: Address
  -> ConfigYamlFilePath
  -> SocketPath
  -> OutputFile
  -> ExceptT CliError IO ()
runQueryFilteredUTxO addr configFp sockPath (OutputFile _outFile) = do
    nc <- liftIO $ parseNodeConfigurationFP configFp
    SomeConsensusProtocol p <- firstExceptT ProtocolError $ mkConsensusProtocol nc Nothing

    case p of
      ptcl@ProtocolRealTPraos{} -> do
        tip <- liftIO $ withIOManager $ \iomgr -> getLocalTip iomgr cfg nm sockPath
        filteredUtxo <- firstExceptT NodeLocalStateQueryError $
          queryFilteredUTxOFromLocalState cfg nm sockPath
                                          (Set.singleton addr) (getTipPoint tip)
        liftIO $ putStrLn $ "Filtered UTxO: " ++ show filteredUtxo
        where
          cfg = configCodec ptclcfg
          --FIXME: this works, but we should get the magic properly:
          nm  = Testnet (nodeNetworkMagic (Proxy :: Proxy blk) ptclcfg)
          ProtocolInfo{pInfoConfig = ptclcfg} = protocolInfo ptcl

      _ -> left $ IncorrectProtocolSpecifiedError (ncProtocol nc)

writeProtocolParameters :: FilePath -> PParams -> ExceptT CliError IO ()
writeProtocolParameters fpath pparams =
  handleIOExceptT (IOError fpath) $ LBS.writeFile fpath (encodePretty pparams)
