{-# LANGUAGE NamedFieldPuns #-}
module Main (main) where

import           Cardano.Prelude hiding (option)
import           Prelude (String, error, id)

import           Control.Arrow
import qualified Data.List.NonEmpty as NE
import           Options.Applicative

import           Control.Exception.Safe (catchIO)
import           Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import           Data.Time (UTCTime)
import           System.Exit (ExitCode(..), exitWith)

import           Cardano.Binary (Annotated (..))
import           Cardano.Chain.Common
import           Cardano.Chain.Genesis
import           Cardano.Chain.Slotting
import           Cardano.Chain.UTxO
import           Cardano.Crypto (AProtocolMagic(..), ProtocolMagic, ProtocolMagicId(..), RequiresNetworkMagic(..))

import           Cardano.Common.CommonCLI
import           Cardano.Common.Protocol
import           Cardano.Node.Parsers
import           Cardano.CLI.Ops (decideCLIOps)
import           Cardano.CLI.Run (ClientCommand(..), runCommand)

main :: IO ()
main = do
  CLI{mainCommand, protocol} <- execParser opts
  ops <- decideCLIOps protocol
  catchIO (runCommand ops mainCommand) $
    \err-> do
      hPutStrLn stderr ("Error:\n" <> show err :: String)
      exitWith $ ExitFailure 1

opts :: ParserInfo CLI
opts = info (parseClient <**> helper)
  ( fullDesc
    <> progDesc "Cardano genesis tool."
    <> header "Cardano genesis tool."
  )

data CLI = CLI
  { protocol    :: Protocol
  , mainCommand :: ClientCommand
  }

parseClient :: Parser CLI
parseClient = CLI
    <$> parseProtocolAsCommand
    <*> parseClientCommand

parseClientCommand :: Parser ClientCommand
parseClientCommand =
  subparser
  (mconcat
    [ commandGroup "Genesis"
    , command' "genesis"                        "Perform genesis." $
      Genesis
      <$> parseFilePath    "genesis-output-dir"       "A yet-absent directory where genesis JSON file along with secrets shall be placed."
      <*> parseUTCTime     "start-time"               "Start time of the new cluster to be enshrined in the new genesis."
      <*> parseFilePath    "protocol-parameters-file" "JSON file with protocol parameters."
      <*> parseK
      <*> parseProtocolMagic
      <*> parseTestnetBalanceOptions
      <*> parseFakeAvvmOptions
      <*> (LovelacePortion . fromInteger . fromMaybe 1 <$>
           (optional $
             parseIntegral  "avvm-balance-factor"      "AVVM balances will be multiplied by this factor (defaults to 1)."))
      <*> optional (parseIntegral    "secret-seed"              "Optionally specify the seed of generation.")
    , command' "dump-hardcoded-genesis"         "Write out a hard-coded genesis." $
      DumpHardcodedGenesis
      <$> parseFilePath    "genesis-output-dir"       "A yet-absent directory where genesis JSON file along with secrets shall be placed."
    , command' "print-genesis-hash"             "Compute hash of a genesis file." $
      PrintGenesisHash
      <$> parseFilePath    "genesis-json"             "Genesis JSON file to hash."
    ])
  <|> subparser
  (mconcat
    [ commandGroup "Keys"
    , command' "keygen"                         "Generate a signing key." $
      Keygen
      <$> parseFilePath    "secret"                   "Non-existent file to write the secret key to."
      <*> parseFlag        "no-password"              "Disable password protection."
    , command' "to-verification"                "Extract a verification key in its base64 form." $
      ToVerification
      <$> parseFilePath    "secret"                   "Secret key file to extract from."
      <*> parseFilePath    "to"                       "Non-existent file to write the base64-formatted verification key to."
    , command' "signing-key-public"             "Pretty-print a signing key's verification key (not a secret)." $
      PrettySigningKeyPublic
      <$> parseFilePath    "secret"                   "File name of the secret key to pretty-print."
    , command' "signing-key-address"            "Print address of a signing key." $
      PrintSigningKeyAddress
      <$> parseNetworkMagic
      <*> parseFilePath    "secret"                   "Secret key, whose address is to be printed."
    , command' "migrate-delegate-key-from"      "Migrate a delegate key from an older version." $
      MigrateDelegateKeyFrom
      <$> parseProtocol
      <*> parseFilePath    "to"                       "Output secret key file."
      <*> parseFilePath    "from"                     "Secret key file to migrate."
    ])
  <|> subparser
  (mconcat
    [ commandGroup "Delegation"
    , command' "redelegate"                     "Redelegate genesis authority to a different verification key." $
      Redelegate
      <$> parseProtocolMagicId "protocol-magic"
      <*> (EpochNumber <$>
            parseIntegral   "since-epoch"              "First epoch of effective delegation.")
      <*> parseFilePath    "secret"                   "The genesis key to redelegate from."
      <*> parseFilePath    "delegate-key"             "The operation verification key to delegate to."
      <*> parseFilePath    "certificate"              "Non-existent file to write the certificate to."
    , command' "check-delegation"               "Verify that a given certificate constitutes a valid delegation relationship betwen keys." $
      CheckDelegation
      <$> parseProtocolMagicId "protocol-magic"
      <*> parseFilePath    "certificate"              "The certificate embodying delegation to verify."
      <*> parseFilePath    "issuer-key"               "The genesis key that supposedly delegates."
      <*> parseFilePath    "delegate-key"             "The operation verification key supposedly delegated to."
    ])
  <|> subparser
  (mconcat
    [ commandGroup "Transactions"
    , command' "submit-tx"                      "Submit a raw, signed transaction, in its on-wire representation." $
      SubmitTx
      <$> parseTopologyInfo "PBFT node ID to submit Tx to."
      <*> parseFilePath    "tx"                       "File containing the raw transaction."
      <*> parseCommonCLI
    , command' "issue-genesis-utxo-expenditure" "Write a file with a signed transaction, spending genesis UTxO." $
      SpendGenesisUTxO
      <$> parseFilePath    "tx"                       "Non-existent file that would contain the new transaction."
      <*> parseFilePath    "wallet-key"               "Key that has access to all mentioned genesis UTxO inputs."
      <*> parseAddress     "rich-addr-from"           "Tx source: genesis UTxO richman address (non-HD)."
      <*> (NE.fromList <$> some parseTxOut)
      <*> parseCommonCLI
    ])

parseTestnetBalanceOptions :: Parser TestnetBalanceOptions
parseTestnetBalanceOptions =
  TestnetBalanceOptions
  <$> parseIntegral        "n-poor-addresses"         "Number of poor nodes (with small balance)."
  <*> parseIntegral        "n-delegate-addresses"     "Number of delegate nodes (with huge balance)."
  <*> parseLovelace        "total-balance"            "Total balance owned by these nodes."
  <*> parseLovelacePortion "delegate-share"           "Portion of stake owned by all delegates together."
  <*> parseFlag            "use-hd-addresses"         "Whether generate plain addresses or with hd payload."

parseLovelace :: String -> String -> Parser Lovelace
parseLovelace optname desc =
  either (error . show) id . mkLovelace
  <$> parseIntegral optname desc

parseLovelacePortion :: String -> String -> Parser LovelacePortion
parseLovelacePortion optname desc =
  either (error . show) id . mkLovelacePortion
  <$> parseIntegral optname desc

parseFakeAvvmOptions :: Parser FakeAvvmOptions
parseFakeAvvmOptions =
  FakeAvvmOptions
  <$> parseIntegral        "avvm-entry-count"         "Number of AVVM addresses."
  <*> parseLovelace        "avvm-entry-balance"       "AVVM address."

parseK :: Parser BlockCount
parseK =
  BlockCount
  <$> parseIntegral        "k"                        "The security parameter of the Ouroboros protocol."

parseNetworkMagic :: Parser NetworkMagic
parseNetworkMagic = asum
    [ flag' NetworkMainOrStage $ mconcat [
          long "main-or-staging"
        , help ""
        ]
    , option (fmap NetworkTestnet auto) (
          long "testnet-magic"
       <> metavar "MAGIC"
       <> help "The testnet network magic, decibal"
        )
    ]

parseProtocolMagicId :: String -> Parser ProtocolMagicId
parseProtocolMagicId arg =
  ProtocolMagicId
  <$> parseIntegral        arg                        "The magic number unique to any instance of Cardano."

parseProtocolMagic :: Parser ProtocolMagic
parseProtocolMagic =
  flip AProtocolMagic RequiresMagic . flip Annotated ()
  <$> parseProtocolMagicId "protocol-magic"

parseUTCTime :: String -> String -> Parser UTCTime
parseUTCTime optname desc =
    option (posixSecondsToUTCTime . fromInteger <$> auto) (
            long optname
         <> metavar "POSIXSECONDS"
         <> help desc
    )

parseFilePath :: String -> String -> Parser FilePath
parseFilePath optname desc =
    strOption (
            long optname
         <> metavar "FILEPATH"
         <> help desc
    )
parseIntegral :: Integral a => String -> String -> Parser a
parseIntegral optname desc =
    option (fromInteger <$> auto) (
            long optname
         <> metavar "INT"
         <> help desc
    )

parseFlag :: String -> String -> Parser Bool
parseFlag optname desc =
    flag False True (
            long optname
         <> help desc
    )

-- | Here, we hope to get away with the usage of 'error' in a pure expression,
--   because the CLI-originated values are either used, in which case the error is
--   unavoidable rather early in the CLI tooling scenario (and especially so, if
--   the relevant command ADT constructor is strict, like with ClientCommand), or
--   they are ignored, in which case they are arguably irrelevant.
--   And we're getting a correct-by-construction value that doesn't need to be
--   scrutinised later, so that's an abstraction benefit as well.
cliParseBase58Address :: Text -> Address
cliParseBase58Address =
  either (error . ("Bad Base58 address: " <>) . show) id
  . fromCBORTextAddress

-- | See the rationale for cliParseBase58Address.
cliParseLovelace :: Word64 -> Lovelace
cliParseLovelace =
  either (error . ("Bad Lovelace value: " <>) . show) id
  . mkLovelace

parseAddress :: String -> String -> Parser Address
parseAddress opt desc = option (cliParseBase58Address <$> auto)
  ( long       opt
    <> metavar "ADDR"
    <> help    desc
  )

parseTxOut :: Parser TxOut
parseTxOut = option (uncurry TxOut
                     . Control.Arrow.first  cliParseBase58Address
                     . Control.Arrow.second cliParseLovelace
                     <$> auto)
  ( long       "txout"
    <> metavar "ADDR:LOVELACE"
    <> help    "Specify a transaction output, as a pair of an address and lovelace."
  )
