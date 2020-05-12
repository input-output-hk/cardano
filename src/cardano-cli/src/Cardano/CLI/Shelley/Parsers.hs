module Cardano.CLI.Shelley.Parsers
  ( -- * CLI command parser
    parseShelleyCommands

    -- * CLI command and flag types
  , module Cardano.CLI.Shelley.Commands
  ) where

import           Prelude (String)
import           Cardano.Prelude hiding (option)

import qualified Data.IP as IP
import           Data.Ratio (approxRational)
import qualified Data.Text as Text
import           Data.Time.Clock (UTCTime)
import           Data.Time.Format (defaultTimeLocale, iso8601DateFormat, parseTimeOrError)
import           Options.Applicative (Parser)
import qualified Options.Applicative as Opt

import           Ouroboros.Consensus.BlockchainTime (SystemStart (..))
import qualified Shelley.Spec.Ledger.BaseTypes as Shelley
import qualified Shelley.Spec.Ledger.Coin as Shelley
import qualified Shelley.Spec.Ledger.TxData as Shelley

import           Cardano.Api
import           Cardano.Slotting.Slot (EpochNo (..))

import           Cardano.Config.Types (SigningKeyFile(..), CertificateFile (..))
import           Cardano.Config.Shelley.OCert (KESPeriod(..))
import           Cardano.CLI.Key (VerificationKeyFile(..))
import           Cardano.Common.Parsers (parseNodeAddress)

import           Cardano.CLI.Shelley.Commands


--
-- Shelley CLI command parsers
--

parseShelleyCommands :: Parser ShelleyCommand
parseShelleyCommands =
  Opt.subparser $
    mconcat
      [ Opt.command "address"
          (Opt.info (AddressCmd <$> pAddressCmd) $ Opt.progDesc "Shelley address commands")
      , Opt.command "stake-address"
          (Opt.info (StakeAddressCmd <$> pStakeAddress) $ Opt.progDesc "Shelley stake address commands")
      , Opt.command "transaction"
          (Opt.info (TransactionCmd <$> pTransaction) $ Opt.progDesc "Shelley transaction commands")
      , Opt.command "node"
          (Opt.info (NodeCmd <$> pNodeCmd) $ Opt.progDesc "Shelley node operaton commands")
      , Opt.command "stake-pool"
          (Opt.info (PoolCmd <$> pPoolCmd) $ Opt.progDesc "Shelley stake pool commands")
      , Opt.command "query"
          (Opt.info (QueryCmd <$> pQueryCmd) . Opt.progDesc $
             mconcat
               [ "Shelley node query commands. Will query the local node whose Unix domain socket "
               , "is obtained from the CARDANO_NODE_SOCKET_PATH enviromnent variable."
               ]
            )
      , Opt.command "block"
          (Opt.info (BlockCmd <$> pBlockCmd) $ Opt.progDesc "Shelley block commands")
      , Opt.command "system"
          (Opt.info (SystemCmd <$> pSystemCmd) $ Opt.progDesc "Shelley system commands")
      , Opt.command "devops"
          (Opt.info (DevOpsCmd <$> pDevOpsCmd) $ Opt.progDesc "Shelley devops commands")
      , Opt.command "genesis"
          (Opt.info (GenesisCmd <$> pGenesisCmd) $ Opt.progDesc "Shelley genesis block commands")
      , Opt.command "text-view"
          (Opt.info (TextViewCmd <$> pTextViewCmd) . Opt.progDesc $
             mconcat
               [ "Commands for dealing with Shelley TextView files. "
               , "Transactions, addresses etc are stored on disk as TextView files."
               ]
            )

      ]

pTextViewCmd :: Parser TextViewCmd
pTextViewCmd =
  Opt.subparser $
    mconcat
      [ Opt.command "decode-cbor"
          (Opt.info (TextViewInfo <$> pFilePath Input)
            $ Opt.progDesc "Print a TextView file as decoded CBOR."
            )
      ]



pAddressCmd :: Parser AddressCmd
pAddressCmd =
  Opt.subparser $
    mconcat
      [ Opt.command "key-gen"
          (Opt.info pAddressKeyGen $ Opt.progDesc "Create a single address key pair.")
      , Opt.command "key-hash"
          (Opt.info pAddressKeyHash $ Opt.progDesc "Print the hash of an address key to stdout.")
      , Opt.command "build-staking"
          (Opt.info pAddressBuildStaking $ Opt.progDesc "Build a standard Shelley address (capable of receiving payments and staking).")
      , Opt.command "build-reward"
          (Opt.info pAddressBuildReward $ Opt.progDesc "Build a Shelley reward address (special address for recieving staking rewards).")
      , Opt.command "build-enterprise"
          (Opt.info pAddressBuildEnterprise $ Opt.progDesc "Build a Shelley enterprise address (can recieve payments but not able to stake, eg for exchanges).")
      , Opt.command "build-multisig"
          (Opt.info pAddressBuildMultiSig $ Opt.progDesc "Build a multi-sig address.")
      , Opt.command "info"
          (Opt.info pAddressInfo $ Opt.progDesc "Print information about an address.")
      ]
  where
    pAddressKeyGen :: Parser AddressCmd
    pAddressKeyGen = AddressKeyGen <$> pVerificationKeyFile Output <*> pSigningKeyFile Output

    pAddressKeyHash :: Parser AddressCmd
    pAddressKeyHash = AddressKeyHash <$> pVerificationKeyFile Input

    pAddressBuildStaking :: Parser AddressCmd
    pAddressBuildStaking =
      AddressBuildStaking
        <$> pPaymentVerificationKeyFile
        <*> pStakingVerificationKeyFile


    pAddressBuildReward :: Parser AddressCmd
    pAddressBuildReward = AddressBuildReward <$> pStakingVerificationKeyFile

    pAddressBuildEnterprise :: Parser AddressCmd
    pAddressBuildEnterprise = AddressBuildEnterprise <$> pPaymentVerificationKeyFile

    pAddressBuildMultiSig :: Parser AddressCmd
    pAddressBuildMultiSig = pure AddressBuildMultiSig

    pAddressInfo :: Parser AddressCmd
    pAddressInfo = AddressInfo <$> pAddress


pPaymentVerificationKeyFile :: Parser VerificationKeyFile
pPaymentVerificationKeyFile =
  VerificationKeyFile <$>
    Opt.strOption
      (  Opt.long "payment-verification-key-file"
      <> Opt.metavar "FILEPATH"
      <> Opt.help "Filepath of the payment verification key."
      )

pStakeAddress :: Parser StakeAddressCmd
pStakeAddress =
  Opt.subparser $
    mconcat
      [ Opt.command "register"
          (Opt.info pStakeAddressRegister $ Opt.progDesc "Register a stake address")
      , Opt.command "delegate"
          (Opt.info pStakeAddressDelegate $ Opt.progDesc "Delegate from a stake address to a stake pool")
      , Opt.command "de-register"
          (Opt.info pStakeAddressDeRegister $ Opt.progDesc "De-register a stake address")
      , Opt.command "registration-certificate"
          (Opt.info pStakeAddressRegistrationCert $ Opt.progDesc "Create a stake address registration certificate")
      , Opt.command "deregistration-certificate"
          (Opt.info pStakeAddressDeregistrationCert $ Opt.progDesc "Create a stake address deregistration certificate")
      , Opt.command "delegation-certificate"
          (Opt.info pStakeAddressDelegationCert $ Opt.progDesc "Create a stake address delegation certificate")
      ]
  where
    pStakeAddressRegister :: Parser StakeAddressCmd
    pStakeAddressRegister = StakeKeyRegister <$> pPrivKeyFile <*> parseNodeAddress

    pStakeAddressDelegate :: Parser StakeAddressCmd
    pStakeAddressDelegate =
      StakeKeyDelegate <$> pPrivKeyFile <*> pPoolId <*> pDelegationFee <*> parseNodeAddress

    pStakeAddressDeRegister :: Parser StakeAddressCmd
    pStakeAddressDeRegister = StakeKeyDeRegister <$> pPrivKeyFile <*> parseNodeAddress

    pStakeAddressRegistrationCert :: Parser StakeAddressCmd
    pStakeAddressRegistrationCert = StakeKeyRegistrationCert
                                      <$> pStakingVerificationKeyFile
                                      <*> pOutputFile

    pStakeAddressDeregistrationCert :: Parser StakeAddressCmd
    pStakeAddressDeregistrationCert = StakeKeyDeRegistrationCert
                                        <$> pStakingVerificationKeyFile
                                        <*> pOutputFile

    pStakeAddressDelegationCert :: Parser StakeAddressCmd
    pStakeAddressDelegationCert = StakeKeyDelegationCert
                                    <$> pStakingVerificationKeyFile
                                    <*> pPoolStakingVerificationKeyFile
                                    <*> pOutputFile



    pDelegationFee :: Parser Lovelace
    pDelegationFee =
      Lovelace <$>
        Opt.option Opt.auto
          (  Opt.long "delegation-fee"
          <> Opt.metavar "LOVELACE"
          <> Opt.help "The delegation fee in Lovelace."
          )

pTransaction :: Parser TransactionCmd
pTransaction =
  Opt.subparser $
    mconcat
      [ Opt.command "build-raw"
          (Opt.info pTransactionBuild $ Opt.progDesc "Build a transaction (low-level, inconvenient)")
      , Opt.command "sign"
          (Opt.info pTransactionSign $ Opt.progDesc "Sign a transaction")
      , Opt.command "witness"
          (Opt.info pTransactionWitness $ Opt.progDesc "Witness a transaction")
      , Opt.command "sign-witness"
          (Opt.info pTransactionSignWit $ Opt.progDesc "Sign and witness a transaction")
      , Opt.command "check"
          (Opt.info pTransactionCheck $ Opt.progDesc "Check a transaction")
      , Opt.command "submit"
          (Opt.info pTransactionSubmit . Opt.progDesc $
             mconcat
               [ "Submit a transaction to the local node whose Unix domain socket "
               , "is obtained from the CARDANO_NODE_SOCKET_PATH enviromnent variable."
               ]
            )
      , Opt.command "calculate-min-fee"
          (Opt.info pTransactionCalculateMinFee $ Opt.progDesc "Calulate the min fee for a transaction")
      , Opt.command "info"
          (Opt.info pTransactionInfo $ Opt.progDesc "Print information about a transaction")
      ]
  where
    pTransactionBuild :: Parser TransactionCmd
    pTransactionBuild = TxBuildRaw <$> some pTxIn
                                   <*> some pTxOut
                                   <*> pTxTTL
                                   <*> pTxFee
                                   <*> pTxBodyFile Output
                                   <*> many pCertificate

    pTransactionSign  :: Parser TransactionCmd
    pTransactionSign = TxSign <$> pTxBodyFile Input
                              <*> pSomeSigningKeyFiles
                              <*> pNetwork
                              <*> pTxFile Output

    pTransactionWitness :: Parser TransactionCmd
    pTransactionWitness = pure TxWitness

    pTransactionSignWit :: Parser TransactionCmd
    pTransactionSignWit = pure TxSignWitness

    pTransactionCheck  :: Parser TransactionCmd
    pTransactionCheck = pure TxCheck

    pTransactionSubmit  :: Parser TransactionCmd
    pTransactionSubmit = TxSubmit <$> pTxSubmitFile
                                  <*> pNetwork

    pTransactionCalculateMinFee :: Parser TransactionCmd
    pTransactionCalculateMinFee =
      TxCalculateMinFee
        <$> pTxInCount
        <*> pTxOutCount
        <*> pTxTTL
        <*> pNetwork
        <*> pSomeSigningKeyFiles
        <*> many pCertificate
        <*> pProtocolParamsFile

    pTransactionInfo  :: Parser TransactionCmd
    pTransactionInfo = pure TxInfo


pNodeCmd :: Parser NodeCmd
pNodeCmd =
  Opt.subparser $
    mconcat
      [ Opt.command "key-gen"
          (Opt.info pKeyGenOperator $
             Opt.progDesc "Create a key pair for a node operator's offline \
                         \ key and a new certificate issue counter")
      , Opt.command "key-gen-KES"
          (Opt.info pKeyGenKES $
             Opt.progDesc "Create a key pair for a node KES operational key")
      , Opt.command "key-gen-VRF"
          (Opt.info pKeyGenVRF $
             Opt.progDesc "Create a key pair for a node VRF operational key")
      , Opt.command "issue-op-cert"
          (Opt.info pIssueOpCert $
             Opt.progDesc "Issue a node operational certificate")
      , Opt.command "key-gen-staking"
          (Opt.info pStakingKeyPair $
             Opt.progDesc "Create an address staking key pair")
      , Opt.command "key-gen-stake-pool"
          (Opt.info pStakePoolKeyPair $
             Opt.progDesc "Create a stake pool key pair")
      ]
  where
    pKeyGenOperator :: Parser NodeCmd
    pKeyGenOperator =
      NodeKeyGenCold <$> pVerificationKeyFile Output
                     <*> pSigningKeyFile Output
                     <*> pOperatorCertIssueCounterFile

    pKeyGenKES :: Parser NodeCmd
    pKeyGenKES =
      NodeKeyGenKES <$> pVerificationKeyFile Output <*> pSigningKeyFile Output

    pKeyGenVRF :: Parser NodeCmd
    pKeyGenVRF =
      NodeKeyGenVRF <$> pVerificationKeyFile Output <*> pSigningKeyFile Output

    pIssueOpCert :: Parser NodeCmd
    pIssueOpCert =
      NodeIssueOpCert <$> pKESVerificationKeyFile
                      <*> pColdSigningKeyFile
                      <*> pOperatorCertIssueCounterFile
                      <*> pKesPeriod
                      <*> pOutputFile

    pStakingKeyPair :: Parser NodeCmd
    pStakingKeyPair = NodeStakingKeyGen
                        <$> pVerificationKeyFile Output
                        <*> pSigningKeyFile Output

    pStakePoolKeyPair :: Parser NodeCmd
    pStakePoolKeyPair = NodeStakePoolKeyGen
                          <$> pVerificationKeyFile Output
                          <*> pSigningKeyFile Output


pPoolCmd :: Parser PoolCmd
pPoolCmd =
  Opt.subparser $
    mconcat
      [ Opt.command "register"
          (Opt.info pPoolRegster $ Opt.progDesc "Register a stake pool")
      , Opt.command "re-register"
          (Opt.info pPoolReRegster $ Opt.progDesc "Re-register a stake pool")
      , Opt.command "retire"
          (Opt.info pPoolRetire $ Opt.progDesc "Retire a stake pool")
      , Opt.command "registration-certificate"
          (Opt.info pStakePoolRegistrationCert $ Opt.progDesc "Create a stake pool registration certificate")
      , Opt.command "deregistration-certificate"
          (Opt.info pStakePoolRetirmentCert $ Opt.progDesc "Create a stake pool deregistration certificate")
      ]
  where
    pPoolRegster :: Parser PoolCmd
    pPoolRegster = PoolRegister <$> pPoolId

    pPoolReRegster :: Parser PoolCmd
    pPoolReRegster = PoolReRegister <$> pPoolId

    pPoolRetire :: Parser PoolCmd
    pPoolRetire = PoolRetire <$> pPoolId <*> pEpochNo <*> parseNodeAddress


pQueryCmd :: Parser QueryCmd
pQueryCmd =
  Opt.subparser $
    mconcat
      [ Opt.command "pool-id"
          (Opt.info pQueryPoolId $ Opt.progDesc "Get the node's pool id")
      , Opt.command "protocol-parameters"
          (Opt.info pQueryProtocolParameters $ Opt.progDesc "Get the node's current protocol parameters")
      , Opt.command "tip"
          (Opt.info pQueryTip $ Opt.progDesc "Get the node's current tip (slot no, hash, block no)")
      , Opt.command "filtered-utxo"
          (Opt.info pQueryFilteredUTxO $ Opt.progDesc "Get the node's current UTxO filtered by address")
      , Opt.command "version"
          (Opt.info pQueryVersion $ Opt.progDesc "Get the node version")
      , Opt.command "status"
          (Opt.info pQueryStatus $ Opt.progDesc "Get the status of the node")
      ]
  where
    pQueryPoolId :: Parser QueryCmd
    pQueryPoolId = QueryPoolId <$> parseNodeAddress

    pQueryProtocolParameters :: Parser QueryCmd
    pQueryProtocolParameters =
      QueryProtocolParameters
        <$> pNetwork
        <*> pMaybeOutputFile

    pQueryTip :: Parser QueryCmd
    pQueryTip = QueryTip <$> pNetwork

    pQueryFilteredUTxO :: Parser QueryCmd
    pQueryFilteredUTxO =
      QueryFilteredUTxO
        <$> pHexEncodedAddress
        <*> pNetwork
        <*> pMaybeOutputFile

    pQueryVersion :: Parser QueryCmd
    pQueryVersion = QueryVersion <$> parseNodeAddress

    pQueryStatus :: Parser QueryCmd
    pQueryStatus = QueryStatus <$> parseNodeAddress


pBlockCmd :: Parser BlockCmd
pBlockCmd =
  Opt.subparser $
    mconcat
      [ Opt.command "info"
          (Opt.info pBlockInfo $ Opt.progDesc "Get the node's pool id")
      ]
  where
    pBlockInfo :: Parser BlockCmd
    pBlockInfo = BlockInfo <$> pBlockId <*> parseNodeAddress

pDevOpsCmd :: Parser DevOpsCmd
pDevOpsCmd =
  Opt.subparser $
    mconcat
      [ Opt.command "protocol-update"
          (Opt.info pProtocolUpdate $ Opt.progDesc "Protocol update")
      , Opt.command "cold-keys"
          (Opt.info pColdKeys $ Opt.progDesc "Cold keys")
      ]
  where
    pProtocolUpdate :: Parser DevOpsCmd
    pProtocolUpdate = DevOpsProtocolUpdate <$> pPrivKeyFile

    pColdKeys :: Parser DevOpsCmd
    pColdKeys = DevOpsColdKeys <$> pGenesisKeyFile

    pGenesisKeyFile :: Parser GenesisKeyFile
    pGenesisKeyFile =
      GenesisKeyFile <$>
        Opt.strOption
          (  Opt.long "genesis-key"
          <> Opt.metavar "FILE"
          <> Opt.help "The genesis key file."
          )


pSystemCmd :: Parser SystemCmd
pSystemCmd =
  Opt.subparser $
    mconcat
      [ Opt.command "start"
          (Opt.info pSystemStart $ Opt.progDesc "Start system")
      , Opt.command "stop"
          (Opt.info pSystemStop $ Opt.progDesc "Stop system")
      ]
  where
    pSystemStart :: Parser SystemCmd
    pSystemStart = SysStart <$> pGenesisFile <*> parseNodeAddress

    pSystemStop :: Parser SystemCmd
    pSystemStop = SysStop <$> parseNodeAddress


pGenesisCmd :: Parser GenesisCmd
pGenesisCmd =
  Opt.subparser $
    mconcat
      [ Opt.command "key-gen-genesis"
          (Opt.info pGenesisKeyGen $
             Opt.progDesc "Create a Shelley genesis key pair")
      , Opt.command "key-gen-delegate"
          (Opt.info pGenesisDelegateKeyGen $
             Opt.progDesc "Create a Shelley genesis delegate key pair")
      , Opt.command "key-gen-utxo"
          (Opt.info pGenesisUTxOKeyGen $
             Opt.progDesc "Create a Shelley genesis UTxO key pair")
      , Opt.command "key-hash"
          (Opt.info pGenesisKeyHash $
             Opt.progDesc "Print the identifier (hash) of a public key")
      , Opt.command "get-ver-key"
          (Opt.info pGenesisVerKey $
             Opt.progDesc "Derive the verification key from a signing key")
      , Opt.command "initial-addr"
          (Opt.info pGenesisAddr $
             Opt.progDesc "Get the address for an initial UTxO based on the verification key")
      , Opt.command "initial-txin"
          (Opt.info pGenesisTxIn $
             Opt.progDesc "Get the TxIn for an initial UTxO based on the verification key")
      , Opt.command "create"
          (Opt.info pGenesisCreate $
             Opt.progDesc ("Create a Shelley genesis file from a genesis "
                        ++ "template and genesis/delegation/spending keys."))
      ]
  where
    pGenesisKeyGen :: Parser GenesisCmd
    pGenesisKeyGen =
      GenesisKeyGenGenesis <$> pVerificationKeyFile Output <*> pSigningKeyFile Output

    pGenesisDelegateKeyGen :: Parser GenesisCmd
    pGenesisDelegateKeyGen =
      GenesisKeyGenDelegate <$> pVerificationKeyFile Output
                            <*> pSigningKeyFile Output
                            <*> pOperatorCertIssueCounterFile

    pGenesisUTxOKeyGen :: Parser GenesisCmd
    pGenesisUTxOKeyGen =
      GenesisKeyGenUTxO <$> pVerificationKeyFile Output <*> pSigningKeyFile Output

    pGenesisKeyHash :: Parser GenesisCmd
    pGenesisKeyHash =
      GenesisKeyHash <$> pVerificationKeyFile Input

    pGenesisVerKey :: Parser GenesisCmd
    pGenesisVerKey =
      GenesisVerKey <$> pVerificationKeyFile Output <*> pSigningKeyFile Output

    pGenesisAddr :: Parser GenesisCmd
    pGenesisAddr =
      GenesisAddr <$> pVerificationKeyFile Input

    pGenesisTxIn :: Parser GenesisCmd
    pGenesisTxIn =
      GenesisTxIn <$> pVerificationKeyFile Input

    pGenesisCreate :: Parser GenesisCmd
    pGenesisCreate =
      GenesisCreate <$> pGenesisDir
                    <*> pGenesisNumGenesisKeys
                    <*> pGenesisNumUTxOKeys
                    <*> pMaybeSystemStart
                    <*> pInitialSupply

    pGenesisDir :: Parser GenesisDir
    pGenesisDir =
      GenesisDir <$>
        Opt.strOption
          (  Opt.long "genesis-dir"
          <> Opt.metavar "DIR"
          <> Opt.help "The genesis directory containing the genesis template and required genesis/delegation/spending keys."
          )

    pMaybeSystemStart :: Parser (Maybe SystemStart)
    pMaybeSystemStart =
      Opt.optional $
        SystemStart . convertTime <$>
          Opt.strOption
            (  Opt.long "start-time"
            <> Opt.metavar "UTC_TIME"
            <> Opt.help "The genesis start time in YYYY-MM-DDThh:mm:ssZ format. If unspecified, will be the current time +30 seconds."
            )

    pGenesisNumGenesisKeys :: Parser Word
    pGenesisNumGenesisKeys =
        Opt.option Opt.auto
          (  Opt.long "gen-genesis-keys"
          <> Opt.metavar "INT"
          <> Opt.help "The number of genesis keys to make [default is 0]."
          <> Opt.value 0
          )

    pGenesisNumUTxOKeys :: Parser Word
    pGenesisNumUTxOKeys =
        Opt.option Opt.auto
          (  Opt.long "gen-utxo-keys"
          <> Opt.metavar "INT"
          <> Opt.help "The number of UTxO keys to make [default is 0]."
          <> Opt.value 0
          )

    convertTime :: String -> UTCTime
    convertTime =
      parseTimeOrError False defaultTimeLocale (iso8601DateFormat $ Just "%H:%M:%SZ")

    pInitialSupply :: Parser (Maybe Lovelace)
    pInitialSupply =
      Opt.optional $
      Lovelace <$>
        Opt.option Opt.auto
          (  Opt.long "supply"
          <> Opt.metavar "LOVELACE"
          <> Opt.help "The initial coin supply in Lovelace which will be evenly distributed across initial stake holders."
          )


--
-- Shelley CLI flag parsers
--

data FileDirection
  = Input
  | Output
  deriving (Eq, Show)

pProtocolParamsFile :: Parser ProtocolParamsFile
pProtocolParamsFile =
 ProtocolParamsFile <$>
   Opt.strOption
     (  Opt.long "protocol-params-file"
     <> Opt.metavar "FILEPATH"
     <> Opt.help "Filepath of the JSON-encoded protocol parameters file"
     )

pCertificate :: Parser CertificateFile
pCertificate =
 CertificateFile <$>
   Opt.strOption
     (  Opt.long "certificate"
     <> Opt.metavar "FILEPATH"
     <> Opt.help "Filepath of the certificate. This encompasses all \
                 \types of certificates (stake pool certificates, \
                 \stake key certificates etc)"
     )

pColdSigningKeyFile :: Parser SigningKeyFile
pColdSigningKeyFile =
  SigningKeyFile <$>
   Opt.strOption
     (  Opt.long "cold-signing-key-file"
     <> Opt.metavar "FILEPATH"
     <> Opt.help "Filepath of the cold signing key."
     )

pSomeSigningKeyFiles :: Parser [SigningKeyFile]
pSomeSigningKeyFiles =
  some $
    SigningKeyFile <$>
      Opt.strOption
      (  Opt.long "signing-key-file"
      <> Opt.metavar "FILEPATH"
      <> Opt.help ("Input filepath of the signing key (one or more).")
      )

pSigningKeyFile :: FileDirection -> Parser SigningKeyFile
pSigningKeyFile fdir =
  SigningKeyFile <$>
   Opt.strOption
     (  Opt.long "signing-key-file"
     <> Opt.metavar "FILEPATH"
     <> Opt.help (show fdir ++ " filepath of the signing key.")
     )

pBlockId :: Parser BlockId
pBlockId =
  BlockId <$>
    Opt.strOption
      (  Opt.long "block-id"
      <> Opt.metavar "STRING"
      <> Opt.help "The block identifier."
      )

pKesPeriod :: Parser KESPeriod
pKesPeriod =
  KESPeriod <$>
  Opt.option Opt.auto (  Opt.long "kes-period"
                      <> Opt.metavar "NATURAL"
                      <> Opt.help "The start of the KES key validity period."
                      )

pEpochNo :: Parser EpochNo
pEpochNo =
  EpochNo <$>
    Opt.option Opt.auto
      (  Opt.long "epoch"
      <> Opt.metavar "INT"
      <> Opt.help "The epoch number."
      )

pGenesisFile :: Parser GenesisFile
pGenesisFile =
  GenesisFile <$>
    Opt.strOption
      (  Opt.long "genesis"
      <> Opt.metavar "FILE"
      <> Opt.help "The genesis file."
      )

pOperatorCertIssueCounterFile :: Parser OpCertCounterFile
pOperatorCertIssueCounterFile =
  OpCertCounterFile <$>
    Opt.strOption
      (  Opt.long "operational-certificate-issue-counter"
      <> Opt.metavar "FILE"
      <> Opt.help "The file with the issue counter for the operational certificate."
      )

pMaybeOutputFile :: Parser (Maybe OutputFile)
pMaybeOutputFile =
  optional $
    OutputFile <$>
      Opt.strOption
        (  Opt.long "out-file"
        <> Opt.metavar "FILE"
        <> Opt.help "Optional output file. Default is to write to stdout."
        )

pOutputFile :: Parser OutputFile
pOutputFile =
  OutputFile <$>
    Opt.strOption
      (  Opt.long "out-file"
      <> Opt.metavar "FILE"
      <> Opt.help "The output file."
      )

pFilePath :: FileDirection -> Parser FilePath
pFilePath fdir =
  Opt.strOption
    (  Opt.long "file"
    <> Opt.metavar "FILENAME"
    <> Opt.help (show fdir ++ " file.")
    )

pPoolId :: Parser PoolId
pPoolId =
  PoolId <$>
    Opt.strOption
      (  Opt.long "pool-id"
      <> Opt.metavar "STRING"
      <> Opt.help "The pool identifier."
      )

pPrivKeyFile :: Parser PrivKeyFile
pPrivKeyFile =
  PrivKeyFile <$>
    Opt.strOption
      (  Opt.long "private-key"
      <> Opt.metavar "FILE"
      <> Opt.help "The private key file."
      )

pVerificationKeyFile :: FileDirection -> Parser VerificationKeyFile
pVerificationKeyFile fdir =
  VerificationKeyFile <$>
    Opt.strOption
      (  Opt.long "verification-key-file"
      <> Opt.metavar "FILEPATH"
      <> Opt.help (show fdir ++ " filepath of the verification key.")
      )

pKESVerificationKeyFile :: Parser VerificationKeyFile
pKESVerificationKeyFile =
  VerificationKeyFile <$>
    Opt.strOption
      (  Opt.long "hot-kes-verification-key-file"
      <> Opt.metavar "FILEPATH"
      <> Opt.help "Filepath of the hot KES verification key."
      )

pNetwork :: Parser Network
pNetwork =
  pMainnet <|> fmap Testnet pTestnetMagic

pMainnet :: Parser Network
pMainnet =
  Opt.flag' Mainnet
    (  Opt.long "mainnet"
    <> Opt.help "Use the mainnet magic id."
    )

pTestnetMagic :: Parser NetworkMagic
pTestnetMagic =
  NetworkMagic <$>
    Opt.option Opt.auto
      (  Opt.long "testnet-magic"
      <> Opt.metavar "INT"
      <> Opt.help "Specify a testnet magic id."
      )

pTxSubmitFile :: Parser FilePath
pTxSubmitFile =
  Opt.strOption
    (  Opt.long "tx-filepath"
    <> Opt.metavar "FILEPATH"
    <> Opt.help "Filepath of the transaction you intend to submit."
    )

pTxIn :: Parser TxIn
pTxIn =
  Opt.option (Opt.maybeReader (parseTxIn . Text.pack))
    (  Opt.long "tx-in"
    <> Opt.metavar "TX_IN"
    <> Opt.help "The input transaction as TxId#TxIx where TxId is the transaction hash and TxIx is the index."
    )

pTxOut :: Parser TxOut
pTxOut =
  Opt.option (Opt.maybeReader (parseTxOut . Text.pack))
    (  Opt.long "tx-out"
    <> Opt.metavar "TX_OUT"
    <> Opt.help "The ouput transaction as TxOut+Lovelace where TxOut is the hex encoded address followed by the amount in Lovelace."
    )

pTxTTL :: Parser SlotNo
pTxTTL =
  SlotNo <$>
    Opt.option Opt.auto
      (  Opt.long "ttl"
      <> Opt.metavar "SLOT_COUNT"
      <> Opt.help "Time to live (in slots)."
      )

pTxFee :: Parser Lovelace
pTxFee =
  Lovelace <$>
    Opt.option Opt.auto
      (  Opt.long "fee"
      <> Opt.metavar "LOVELACE"
      <> Opt.help "The fee amount in Lovelace."
      )

pTxBodyFile :: FileDirection -> Parser TxBodyFile
pTxBodyFile fdir =
  TxBodyFile <$>
    Opt.strOption
      (  Opt.long "tx-body-file"
      <> Opt.metavar "FILEPATH"
      <> Opt.help (show fdir ++ " filepath of the TxBody.")
      )

pTxFile :: FileDirection -> Parser TxFile
pTxFile fdir =
  TxFile <$>
    Opt.strOption
      (  Opt.long "tx-file"
      <> Opt.metavar "FILEPATH"
      <> Opt.help (show fdir ++ " filepath of the Tx.")
      )

pTxInCount :: Parser TxInCount
pTxInCount =
  TxInCount <$>
    Opt.option Opt.auto
      (  Opt.long "tx-in-count"
      <> Opt.metavar "INT"
      <> Opt.help "The number of transaction inputs."
      )

pTxOutCount :: Parser TxOutCount
pTxOutCount =
  TxOutCount <$>
    Opt.option Opt.auto
      (  Opt.long "tx-out-count"
      <> Opt.metavar "INT"
      <> Opt.help "The number of transaction outputs."
      )

pHexEncodedAddress :: Parser Address
pHexEncodedAddress =
  Opt.option (Opt.maybeReader (addressFromHex . Text.pack))
    (  Opt.long "address"
    <> Opt.metavar "ADDRESS"
    <> Opt.help "A hex-encoded Cardano address."
    )

pAddress :: Parser Text
pAddress =
  Text.pack <$>
    Opt.strOption
      (  Opt.long "address"
      <> Opt.metavar "ADDRESS"
      <> Opt.help "A Cardano address"
      )


pStakingVerificationKeyFile :: Parser VerificationKeyFile
pStakingVerificationKeyFile =
  VerificationKeyFile <$>
    Opt.strOption
      (  Opt.long "staking-verification-key-file"
      <> Opt.metavar "FILEPATH"
      <> Opt.help ("Filepath of the staking verification key.")
      )

pPoolStakingVerificationKeyFile :: Parser VerificationKeyFile
pPoolStakingVerificationKeyFile =
  VerificationKeyFile <$>
    Opt.strOption
      (  Opt.long "stake-pool-verification-key-file"
      <> Opt.metavar "FILEPATH"
      <> Opt.help ("Filepath of the stake pool verification key.")
      )

pVRFVerificationKeyFile :: Parser VerificationKeyFile
pVRFVerificationKeyFile =
  VerificationKeyFile <$>
    Opt.strOption
      (  Opt.long "vrf-verification-key-file"
      <> Opt.metavar "FILEPATH"
      <> Opt.help ("Filepath of the VRF verification key.")
      )

pRewardAcctVerificationKeyFile :: Parser VerificationKeyFile
pRewardAcctVerificationKeyFile =
  VerificationKeyFile <$>
    Opt.strOption
      (  Opt.long "reward-account-verification-key-file"
      <> Opt.metavar "FILEPATH"
      <> Opt.help ("Filepath of the reward account staking verification key.")
      )

pPoolOwner :: Parser VerificationKeyFile
pPoolOwner =
  VerificationKeyFile <$>
    Opt.strOption
      (  Opt.long "pool-owner-staking-verification-key"
      <> Opt.metavar "FILEPATH"
      <> Opt.help ("Filepath of the pool owner staking verification key.")
      )

pPoolPledge :: Parser ShelleyCoin
pPoolPledge =
  Shelley.Coin <$>
    Opt.option Opt.auto
      (  Opt.long "pool-pledge"
      <> Opt.metavar "INT"
      <> Opt.help "The stake pool's pledge."
      )


pPoolCost :: Parser ShelleyCoin
pPoolCost =
  Shelley.Coin <$>
    Opt.option Opt.auto
      (  Opt.long "pool-cost"
      <> Opt.metavar "INT"
      <> Opt.help "The stake pool's cost."
      )

pPoolMargin :: Parser ShelleyStakePoolMargin
pPoolMargin =
  (\dbl -> maybeOrFail . Shelley.mkUnitInterval $ approxRational (dbl :: Double) 1) <$>
    Opt.option Opt.auto
      (  Opt.long "pool-margin"
      <> Opt.metavar "DOUBLE"
      <> Opt.help "The stake pool's margin."
      )
  where
    maybeOrFail (Just mgn) = mgn
    maybeOrFail Nothing = panic "Pool margin outside of [0,1] range."

_pPoolRelay :: Parser ShelleyStakePoolRelay
_pPoolRelay = Shelley.SingleHostAddr Shelley.SNothing
               <$> (Shelley.maybeToStrictMaybe <$> optional _pIpV4)
               <*> (Shelley.maybeToStrictMaybe <$> optional _pIpV6)

_pIpV4 :: Parser IP.IPv4
_pIpV4 = Opt.option (Opt.maybeReader readMaybe :: Opt.ReadM IP.IPv4)
          (  Opt.long "pool-relay-ipv4"
          <> Opt.metavar "STRING"
          <> Opt.help "The stake pool relay's IpV4 address"
          )

_pIpV6 :: Parser IP.IPv6
_pIpV6 = Opt.option (Opt.maybeReader readMaybe :: Opt.ReadM IP.IPv6)
          (  Opt.long "pool-relay-ipv6"
          <> Opt.metavar "STRING"
          <> Opt.help "The stake pool relay's IpV6 address"
          )

pStakePoolRegistrationCert :: Parser PoolCmd
pStakePoolRegistrationCert =
 PoolRegistrationCert
  <$> pPoolStakingVerificationKeyFile
  <*> pVRFVerificationKeyFile
  <*> pPoolPledge
  <*> pPoolCost
  <*> pPoolMargin
  <*> pRewardAcctVerificationKeyFile
  <*> some pPoolOwner
  <*> pure []
  <*> pOutputFile

pStakePoolRetirmentCert :: Parser PoolCmd
pStakePoolRetirmentCert =
  PoolRetirmentCert
    <$> pPoolStakingVerificationKeyFile
    <*> pEpochNo
    <*> pOutputFile
