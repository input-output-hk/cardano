{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE GADTs #-}

module Cardano.CLI.Shelley.Run.Genesis
  ( ShelleyGenesisCmdError
  , renderShelleyGenesisCmdError
  , runGenesisCmd
  ) where

import           Cardano.Prelude

import qualified Data.Aeson as Aeson
import           Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import           Data.Char (isDigit)
import qualified Data.List as List
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import           Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)

import           System.Directory (createDirectoryIfMissing, listDirectory)
import           System.FilePath ((</>), takeExtension, takeExtensions)
import           System.IO.Error (isDoesNotExistError)

import           Control.Monad.Trans.Except (ExceptT)
import           Control.Monad.Trans.Except.Extra (firstExceptT, handleIOExceptT,
                   hoistEither, left, newExceptT)

import           Cardano.Api.Typed
import           Cardano.Api.TextView
import           Cardano.Api.Shelley.Genesis

import           Ouroboros.Consensus.BlockchainTime (SystemStart (..))
import           Ouroboros.Consensus.Shelley.Protocol (TPraosStandardCrypto)

import qualified Shelley.Spec.Ledger.Coin    as Ledger
import qualified Shelley.Spec.Ledger.Address as Ledger
import qualified Shelley.Spec.Ledger.Keys    as Ledger

import           Cardano.CLI.Shelley.Commands
import           Cardano.CLI.Shelley.Parsers (renderTxIn)
import           Cardano.CLI.Shelley.KeyGen (ShelleyKeyGenError,
                   renderShelleyKeyGenError)

data ShelleyGenesisCmdError
  = ShelleyGenesisCmdGenesisKeyGenError !ShelleyKeyGenError
  | ShelleyGenesisCmdGenesisUTxOKeyError !(FileError TextEnvelopeError)
  | ShelleyGenesisCmdOnlyShelleyAddresses
  | ShelleyGenesisCmdOnlyShelleyAddressesNotReward
  | ShelleyGenesisCmdOperatorKeyGenError !ShelleyKeyGenError
  | ShelleyGenesisCmdOperatorVrfKeyGenError !(FileError TextEnvelopeError)
  | ShelleyGenesisCmdReadGenesisAesonDecodeError !FilePath !Text
  | ShelleyGenesisCmdReadGenesisIOError !FilePath !IOException
  | ShelleyGenesisCmdReadGenesisUTxOVerKeyError !(FileError TextEnvelopeError)
  | ShelleyGenesisCmdReadIndexedVerKeyError !(FileError TextEnvelopeError)
  | ShelleyGenesisCmdReadIndexedVrfKeyError !(FileError TextEnvelopeError)
  | ShelleyGenesisCmdReadSignKeyError !(FileError TextEnvelopeError)
  | ShelleyGenesisCmdReadVerKeyError !(FileError TextEnvelopeError)
  | ShelleyGenesisCmdUTxOKeyGenError !ShelleyKeyGenError
  | ShelleyGenesisCmdWriteDefaultGenesisIOError !FilePath !IOException
  | ShelleyGenesisCmdWriteGenesisIOError !FilePath !IOException
  | ShelleyGenesisCmdWriteOperationalCertError !FilePath !OperationalCertIssueError
  | ShelleyGenesisMismatchedGenesisKeyFiles [Int] [Int] [Int]
  | ShelleyGenesisFilesNoIndex [FilePath]
  | ShelleyGenesisFilesDupIndex [FilePath]
  | ShelleyGenesisCmdWriteFileError !(FileError ())
  deriving Show

renderShelleyGenesisCmdError :: ShelleyGenesisCmdError -> Text
renderShelleyGenesisCmdError err =
  case err of
    ShelleyGenesisCmdUTxOKeyGenError keyErr ->
      "Error while generating the genesis UTxO keys:" <> renderShelleyKeyGenError keyErr
    ShelleyGenesisCmdReadVerKeyError keyErr ->
      "Error while reading genesis verification key: " <> Text.pack (displayError keyErr)
    ShelleyGenesisCmdReadSignKeyError keyErr ->
      "Error while reading the genesis signing key: " <> Text.pack (displayError keyErr)
    ShelleyGenesisCmdReadGenesisUTxOVerKeyError keyErr ->
      "Error while reading the genesis UTxO verification key: " <> Text.pack (displayError keyErr)
    ShelleyGenesisCmdOnlyShelleyAddressesNotReward ->
      "Please only supply Shelley addresses. Reward account found."
    ShelleyGenesisCmdOnlyShelleyAddresses ->
      "Please supply only shelley addresses."
    ShelleyGenesisCmdOperatorKeyGenError keyErr ->
      "Error generating genesis operational key: " <> renderShelleyKeyGenError keyErr
    ShelleyGenesisCmdOperatorVrfKeyGenError keyErr ->
      "Error generating genesis delegate VRF key: " <> Text.pack (displayError keyErr)
    ShelleyGenesisCmdReadIndexedVerKeyError keyErr ->
      "Error reading indexed verification key: " <> Text.pack (displayError keyErr)
    ShelleyGenesisCmdReadIndexedVrfKeyError fileErr ->
      "Error reading indexed VRF verification key: " <> Text.pack (displayError fileErr)
    ShelleyGenesisCmdGenesisUTxOKeyError keyErr ->
      "Error reading genesis UTxO key: " <> Text.pack (displayError keyErr)
    ShelleyGenesisCmdReadGenesisAesonDecodeError fp decErr ->
      "Error while decoding Shelley genesis at: " <> textShow fp <> " Error: " <> textShow decErr
    ShelleyGenesisCmdReadGenesisIOError fp ioException ->
      "Error while reading Shelley genesis at: " <> textShow fp <> " Error: " <> textShow ioException
    ShelleyGenesisCmdWriteDefaultGenesisIOError fp ioException ->
      "Error while writing default genesis at: " <> textShow fp <> " Error: " <> textShow ioException
    ShelleyGenesisCmdWriteGenesisIOError fp ioException ->
      "Error while writing Shelley genesis at: " <> textShow fp <> " Error: " <> textShow ioException
    ShelleyGenesisCmdWriteOperationalCertError fp opCertErr ->
      "Error while writing Shelley genesis operational certificate at: "
         <> textShow fp
         <> " Error: "
         <> Text.pack (displayError opCertErr)
    ShelleyGenesisCmdGenesisKeyGenError keyGenErr ->
      "Error generating the genesis keys: " <> renderShelleyKeyGenError keyGenErr
    ShelleyGenesisMismatchedGenesisKeyFiles gfiles dfiles vfiles ->
      "Mismatch between the files found:\n"
        <> "Genesis key file indexes:      " <> textShow gfiles
        <> "delegate key file indexes:     " <> textShow dfiles
        <> "delegate VRF key file indexes: " <> textShow vfiles
    ShelleyGenesisFilesNoIndex files ->
      "The genesis keys files are expected to have a numeric index but these do not:\n"
        <> Text.unlines (map Text.pack files)
    ShelleyGenesisFilesDupIndex files ->
      "The genesis keys files are expected to have a unique numeric index but these do not:\n"
        <> Text.unlines (map Text.pack files)
    ShelleyGenesisCmdWriteFileError fileErr ->
      Text.pack (displayError fileErr)


runGenesisCmd :: GenesisCmd -> ExceptT ShelleyGenesisCmdError IO ()
runGenesisCmd (GenesisKeyGenGenesis vk sk) = runGenesisKeyGenGenesis vk sk
runGenesisCmd (GenesisKeyGenDelegate vk sk ctr) = runGenesisKeyGenDelegate vk sk ctr
runGenesisCmd (GenesisKeyGenUTxO vk sk) = runGenesisKeyGenUTxO vk sk
runGenesisCmd (GenesisCmdKeyHash vk) = runGenesisKeyHash vk
runGenesisCmd (GenesisVerKey vk sk) = runGenesisVerKey vk sk
runGenesisCmd (GenesisTxIn vk nw mOutFile) = runGenesisTxIn vk nw mOutFile
runGenesisCmd (GenesisAddr vk nw mOutFile) = runGenesisAddr vk nw mOutFile
runGenesisCmd (GenesisCreate gd gn un ms am nw) = runGenesisCreate gd gn un ms am nw

--
-- Genesis command implementations
--

runGenesisKeyGenGenesis :: VerificationKeyFile -> SigningKeyFile
                        -> ExceptT ShelleyGenesisCmdError IO ()
runGenesisKeyGenGenesis (VerificationKeyFile vkeyPath)
                        (SigningKeyFile skeyPath) = do
    skey <- liftIO $ generateSigningKey AsGenesisKey
    let vkey = getVerificationKey skey
    firstExceptT ShelleyGenesisCmdWriteFileError
      . newExceptT
      $ writeFileTextEnvelope skeyPath (Just skeyDesc) skey
    firstExceptT ShelleyGenesisCmdWriteFileError
      . newExceptT
      $ writeFileTextEnvelope vkeyPath (Just vkeyDesc) vkey
  where
    skeyDesc, vkeyDesc :: TextViewTitle
    skeyDesc = TextViewTitle "Genesis Signing Key"
    vkeyDesc = TextViewTitle "Genesis Verification Key"


runGenesisKeyGenDelegate :: VerificationKeyFile
                         -> SigningKeyFile
                         -> OpCertCounterFile
                         -> ExceptT ShelleyGenesisCmdError IO ()
runGenesisKeyGenDelegate (VerificationKeyFile vkeyPath)
                         (SigningKeyFile skeyPath)
                         (OpCertCounterFile ocertCtrPath) = do
    skey <- liftIO $ generateSigningKey AsGenesisDelegateKey
    let vkey = getVerificationKey skey
    firstExceptT ShelleyGenesisCmdWriteFileError
      . newExceptT
      $ writeFileTextEnvelope skeyPath (Just skeyDesc) skey
    firstExceptT ShelleyGenesisCmdWriteFileError
      . newExceptT
      $ writeFileTextEnvelope vkeyPath (Just vkeyDesc) vkey
    firstExceptT ShelleyGenesisCmdWriteFileError
      . newExceptT
      $ writeFileTextEnvelope ocertCtrPath (Just ocertCtrDesc)
      $ OperationalCertificateIssueCounter
          initialCounter
          (castVerificationKey vkey)  -- Cast to a 'StakePoolKey'
  where
    skeyDesc, vkeyDesc, ocertCtrDesc :: TextViewTitle
    skeyDesc = TextViewTitle "Genesis delegate operator key"
    vkeyDesc = TextViewTitle "Genesis delegate operator key"
    ocertCtrDesc = TextViewTitle $ "Next certificate issue number: " <> BS.pack (show initialCounter)

    initialCounter :: Natural
    initialCounter = 0


runGenesisKeyGenDelegateVRF :: VerificationKeyFile -> SigningKeyFile
                            -> ExceptT ShelleyGenesisCmdError IO ()
runGenesisKeyGenDelegateVRF (VerificationKeyFile vkeyPath)
                            (SigningKeyFile skeyPath) = do
    skey <- liftIO $ generateSigningKey AsVrfKey
    let vkey = getVerificationKey skey
    firstExceptT ShelleyGenesisCmdWriteFileError
      . newExceptT
      $ writeFileTextEnvelope skeyPath (Just skeyDesc) skey
    firstExceptT ShelleyGenesisCmdWriteFileError
      . newExceptT
      $ writeFileTextEnvelope vkeyPath (Just vkeyDesc) vkey
  where
    skeyDesc, vkeyDesc :: TextViewTitle
    skeyDesc = TextViewTitle "VRF Signing Key"
    vkeyDesc = TextViewTitle "VRF Verification Key"


runGenesisKeyGenUTxO :: VerificationKeyFile -> SigningKeyFile
                     -> ExceptT ShelleyGenesisCmdError IO ()
runGenesisKeyGenUTxO (VerificationKeyFile vkeyPath)
                     (SigningKeyFile skeyPath) = do
    skey <- liftIO $ generateSigningKey AsGenesisUTxOKey
    let vkey = getVerificationKey skey
    firstExceptT ShelleyGenesisCmdWriteFileError
      . newExceptT
      $ writeFileTextEnvelope skeyPath (Just skeyDesc) skey
    firstExceptT ShelleyGenesisCmdWriteFileError
      . newExceptT
      $ writeFileTextEnvelope vkeyPath (Just vkeyDesc) vkey
  where
    skeyDesc, vkeyDesc :: TextViewTitle
    skeyDesc = TextViewTitle "Genesis Initial UTxO Signing Key"
    vkeyDesc = TextViewTitle "Genesis Initial UTxO Verification Key"


runGenesisKeyHash :: VerificationKeyFile -> ExceptT ShelleyGenesisCmdError IO ()
runGenesisKeyHash (VerificationKeyFile vkeyPath) = do
    vkey <- firstExceptT ShelleyGenesisCmdReadVerKeyError . newExceptT $
            readFileTextEnvelopeAnyOf
              [ FromSomeType (AsVerificationKey AsGenesisKey)
                             AGenesisKey
              , FromSomeType (AsVerificationKey AsGenesisDelegateKey)
                             AGenesisDelegateKey
              , FromSomeType (AsVerificationKey AsGenesisUTxOKey)
                             AGenesisUTxOKey
              ]
              vkeyPath
    liftIO $ BS.putStrLn (renderKeyHash vkey)
  where
    renderKeyHash :: SomeGenesisKey VerificationKey -> ByteString
    renderKeyHash (AGenesisKey         vk) = renderVerificationKeyHash vk
    renderKeyHash (AGenesisDelegateKey vk) = renderVerificationKeyHash vk
    renderKeyHash (AGenesisUTxOKey     vk) = renderVerificationKeyHash vk

    renderVerificationKeyHash :: Key keyrole => VerificationKey keyrole -> ByteString
    renderVerificationKeyHash = serialiseToRawBytesHex
                              . verificationKeyHash


runGenesisVerKey :: VerificationKeyFile -> SigningKeyFile
                 -> ExceptT ShelleyGenesisCmdError IO ()
runGenesisVerKey (VerificationKeyFile vkeyPath) (SigningKeyFile skeyPath) = do
    skey <- firstExceptT ShelleyGenesisCmdReadVerKeyError . newExceptT $
            readFileTextEnvelopeAnyOf
              [ FromSomeType (AsSigningKey AsGenesisKey)
                             AGenesisKey
              , FromSomeType (AsSigningKey AsGenesisDelegateKey)
                             AGenesisDelegateKey
              , FromSomeType (AsSigningKey AsGenesisUTxOKey)
                             AGenesisUTxOKey
              ]
              skeyPath

    let vkey :: SomeGenesisKey VerificationKey
        vkey = case skey of
          AGenesisKey         sk -> AGenesisKey         (getVerificationKey sk)
          AGenesisDelegateKey sk -> AGenesisDelegateKey (getVerificationKey sk)
          AGenesisUTxOKey     sk -> AGenesisUTxOKey     (getVerificationKey sk)

    firstExceptT ShelleyGenesisCmdWriteFileError . newExceptT . liftIO $
      case vkey of
        AGenesisKey         vk -> writeFileTextEnvelope vkeyPath Nothing vk
        AGenesisDelegateKey vk -> writeFileTextEnvelope vkeyPath Nothing vk
        AGenesisUTxOKey     vk -> writeFileTextEnvelope vkeyPath Nothing vk

data SomeGenesisKey f
     = AGenesisKey         (f GenesisKey)
     | AGenesisDelegateKey (f GenesisDelegateKey)
     | AGenesisUTxOKey     (f GenesisUTxOKey)


runGenesisTxIn :: VerificationKeyFile -> NetworkId -> Maybe OutputFile
               -> ExceptT ShelleyGenesisCmdError IO ()
runGenesisTxIn (VerificationKeyFile vkeyPath) network mOutFile = do
    vkey <- firstExceptT ShelleyGenesisCmdReadGenesisUTxOVerKeyError . newExceptT $
            readFileTextEnvelope (AsVerificationKey AsGenesisUTxOKey) vkeyPath
    let txin = genesisUTxOPseudoTxIn network (verificationKeyHash vkey)
    liftIO $ writeOutput mOutFile (renderTxIn txin)


runGenesisAddr :: VerificationKeyFile -> NetworkId -> Maybe OutputFile
               -> ExceptT ShelleyGenesisCmdError IO ()
runGenesisAddr (VerificationKeyFile vkeyPath) network mOutFile = do
    vkey <- firstExceptT ShelleyGenesisCmdReadGenesisUTxOVerKeyError . newExceptT $
            readFileTextEnvelope (AsVerificationKey AsGenesisUTxOKey) vkeyPath
    let vkh  = verificationKeyHash (castVerificationKey vkey)
        addr = makeShelleyAddress network (PaymentCredentialByKey vkh)
                                  NoStakeAddress
    liftIO $ writeOutput mOutFile (serialiseAddress addr)

writeOutput :: Maybe OutputFile -> Text -> IO ()
writeOutput (Just (OutputFile fpath)) = Text.writeFile fpath
writeOutput Nothing                   = Text.putStrLn


--
-- Create Genesis command implementation
--

runGenesisCreate :: GenesisDir
                 -> Word  -- ^ num genesis & delegate keys to make
                 -> Word  -- ^ num utxo keys to make
                 -> Maybe SystemStart
                 -> Maybe Lovelace
                 -> NetworkId
                 -> ExceptT ShelleyGenesisCmdError IO ()
runGenesisCreate (GenesisDir rootdir)
                 genNumGenesisKeys genNumUTxOKeys
                 mStart mAmount network = do
  liftIO $ do
    createDirectoryIfMissing False rootdir
    createDirectoryIfMissing False gendir
    createDirectoryIfMissing False deldir
    createDirectoryIfMissing False utxodir

  template <- readShelleyGenesis (rootdir </> "genesis.spec.json")

  forM_ [ 1 .. genNumGenesisKeys ] $ \index -> do
    createGenesisKeys  gendir  index
    createDelegateKeys deldir index

  forM_ [ 1 .. genNumUTxOKeys ] $ \index ->
    createUtxoKeys utxodir index

  genDlgs <- readGenDelegsMap gendir deldir
  utxoAddrs <- readInitialFundAddresses utxodir network
  start <- maybe (SystemStart <$> getCurrentTimePlus30) pure mStart

  let finalGenesis = updateTemplate start mAmount genDlgs utxoAddrs template

  writeShelleyGenesis (rootdir </> "genesis.json") finalGenesis
  where
    gendir  = rootdir </> "genesis-keys"
    deldir  = rootdir </> "delegate-keys"
    utxodir = rootdir </> "utxo-keys"

-- -------------------------------------------------------------------------------------------------

createDelegateKeys :: FilePath -> Word -> ExceptT ShelleyGenesisCmdError IO ()
createDelegateKeys dir index = do
  liftIO $ createDirectoryIfMissing False dir
  let strIndex = show index
  runGenesisKeyGenDelegate
        (VerificationKeyFile $ dir </> "delegate" ++ strIndex ++ ".vkey")
        (SigningKeyFile $ dir </> "delegate" ++ strIndex ++ ".skey")
        (OpCertCounterFile $ dir </> "delegate" ++ strIndex ++ ".counter")
  runGenesisKeyGenDelegateVRF
        (VerificationKeyFile $ dir </> "delegate" ++ strIndex ++ ".vrf.vkey")
        (SigningKeyFile $ dir </> "delegate" ++ strIndex ++ ".vrf.skey")

createGenesisKeys :: FilePath -> Word -> ExceptT ShelleyGenesisCmdError IO ()
createGenesisKeys dir index = do
  liftIO $ createDirectoryIfMissing False dir
  let strIndex = show index
  runGenesisKeyGenGenesis
        (VerificationKeyFile $ dir </> "genesis" ++ strIndex ++ ".vkey")
        (SigningKeyFile $ dir </> "genesis" ++ strIndex ++ ".skey")


createUtxoKeys :: FilePath -> Word -> ExceptT ShelleyGenesisCmdError IO ()
createUtxoKeys dir index = do
  liftIO $ createDirectoryIfMissing False dir
  let strIndex = show index
  runGenesisKeyGenUTxO
        (VerificationKeyFile $ dir </> "utxo" ++ strIndex ++ ".vkey")
        (SigningKeyFile $ dir </> "utxo" ++ strIndex ++ ".skey")


-- | Current UTCTime plus 30 seconds
getCurrentTimePlus30 :: ExceptT ShelleyGenesisCmdError IO UTCTime
getCurrentTimePlus30 =
    plus30sec <$> liftIO getCurrentTime
  where
    plus30sec :: UTCTime -> UTCTime
    plus30sec = addUTCTime (30 :: NominalDiffTime)


readShelleyGenesis :: FilePath -> ExceptT ShelleyGenesisCmdError IO (ShelleyGenesis TPraosStandardCrypto)
readShelleyGenesis fpath = do
    readAndDecode
      `catchError` \err ->
        case err of
          ShelleyGenesisCmdReadGenesisIOError _ ioe
            | isDoesNotExistError ioe -> writeDefault
          _                           -> left err
  where
    readAndDecode = do
      lbs <- handleIOExceptT (ShelleyGenesisCmdReadGenesisIOError fpath) $ LBS.readFile fpath
      firstExceptT (ShelleyGenesisCmdReadGenesisAesonDecodeError fpath . Text.pack)
        . hoistEither $ Aeson.eitherDecode' lbs

    defaults :: ShelleyGenesis TPraosStandardCrypto
    defaults = shelleyGenesisDefaults

    writeDefault = do
      handleIOExceptT (ShelleyGenesisCmdWriteDefaultGenesisIOError fpath) $
        LBS.writeFile fpath (encodePretty defaults)
      return defaults


updateTemplate
    :: SystemStart
    -> Maybe Lovelace
    -> Map (Hash GenesisKey) (Hash GenesisDelegateKey, Hash VrfKey)
    -> [Address Shelley]
    -> ShelleyGenesis TPraosStandardCrypto
    -> ShelleyGenesis TPraosStandardCrypto
updateTemplate (SystemStart start) mAmount delKeys utxoAddrs template =
    template
      { sgSystemStart = start
      , sgMaxLovelaceSupply = fromIntegral totalCoin
      , sgGenDelegs = shelleyDelKeys
      , sgInitialFunds = Map.fromList
                          [ (toShelleyAddr addr, toShelleyLovelace v)
                          | (addr, v) <- utxoList ]
      }
  where
    shelleyDelKeys =
      Map.fromList
        [ (gh, Ledger.GenDelegPair gdh h)
        | (GenesisKeyHash gh,
           (GenesisDelegateKeyHash gdh, VrfKeyHash h)) <- Map.toList delKeys
        ]

    totalCoin :: Integer
    totalCoin = case mAmount of
                  Nothing           -> fromIntegral (sgMaxLovelaceSupply template)
                  Just (Lovelace x) -> x

    eachAddrCoin :: Integer
    eachAddrCoin = totalCoin `div` fromIntegral (length utxoAddrs)

    utxoList :: [(Address Shelley, Lovelace)]
    utxoList = fst $ List.foldl' folder ([], totalCoin) utxoAddrs

    folder :: ([(Address Shelley, Lovelace)], Integer)
           -> Address Shelley
           -> ([(Address Shelley, Lovelace)], Integer)
    folder (acc, rest) addr
      | rest > eachAddrCoin + fromIntegral (length utxoAddrs) =
                    ((addr, Lovelace eachAddrCoin) : acc, rest - eachAddrCoin)
      | otherwise = ((addr, Lovelace rest) : acc, 0)

writeShelleyGenesis :: FilePath -> ShelleyGenesis TPraosStandardCrypto -> ExceptT ShelleyGenesisCmdError IO ()
writeShelleyGenesis fpath sg =
  handleIOExceptT (ShelleyGenesisCmdWriteGenesisIOError fpath) $ LBS.writeFile fpath (encodePretty sg)

toShelleyAddr :: Address Shelley -> Ledger.Addr TPraosStandardCrypto
toShelleyAddr (ByronAddress addr)        = Ledger.AddrBootstrap
                                             (Ledger.BootstrapAddress addr)
toShelleyAddr (ShelleyAddress nw pc scr) = Ledger.Addr nw pc scr

toShelleyLovelace :: Lovelace -> Ledger.Coin
toShelleyLovelace (Lovelace l) = Ledger.Coin l


-- -------------------------------------------------------------------------------------------------

readGenDelegsMap :: FilePath -> FilePath
                 -> ExceptT ShelleyGenesisCmdError IO
                            (Map (Hash GenesisKey)
                                 (Hash GenesisDelegateKey, Hash VrfKey))
readGenDelegsMap gendir deldir = do
    gkm <- readGenesisKeys gendir
    dkm <- readDelegateKeys deldir
    vkm <- readDelegateVrfKeys deldir

    let combinedMap :: Map Int (VerificationKey GenesisKey,
                                (VerificationKey GenesisDelegateKey,
                                 VerificationKey VrfKey))
        combinedMap =
          Map.intersectionWith (,)
            gkm
            (Map.intersectionWith (,)
               dkm vkm)

    -- All the maps should have an identical set of keys. Complain if not.
    let gkmExtra = gkm Map.\\ combinedMap
        dkmExtra = dkm Map.\\ combinedMap
        vkmExtra = vkm Map.\\ combinedMap
    unless (Map.null gkmExtra && Map.null dkmExtra && Map.null vkmExtra) $
      throwError $ ShelleyGenesisMismatchedGenesisKeyFiles
                     (Map.keys gkm) (Map.keys dkm) (Map.keys vkm)

    let delegsMap :: Map (Hash GenesisKey)
                         (Hash GenesisDelegateKey, Hash VrfKey)
        delegsMap =
          Map.fromList [ (gh, (dh, vh))
                       | (g,(d,v)) <- Map.elems combinedMap
                       , let gh = verificationKeyHash g
                             dh = verificationKeyHash d
                             vh = verificationKeyHash v
                       ]

    pure delegsMap


readGenesisKeys :: FilePath -> ExceptT ShelleyGenesisCmdError IO
                                       (Map Int (VerificationKey GenesisKey))
readGenesisKeys gendir = do
  files <- liftIO (listDirectory gendir)
  fileIxs <- extractFileNameIndexes [ gendir </> file
                                    | file <- files
                                    , takeExtension file == ".vkey" ]
  firstExceptT ShelleyGenesisCmdReadIndexedVerKeyError $
    Map.fromList <$>
      sequence
        [ (,) ix <$> readKeyFile file
        | (file, ix) <- fileIxs ]
  where
    readKeyFile = newExceptT
                . readFileTextEnvelope (AsVerificationKey AsGenesisKey)

readDelegateKeys :: FilePath
                 -> ExceptT ShelleyGenesisCmdError IO
                            (Map Int (VerificationKey GenesisDelegateKey))
readDelegateKeys deldir = do
  files <- liftIO (listDirectory deldir)
  fileIxs <- extractFileNameIndexes [ deldir </> file
                                    | file <- files
                                    , takeExtensions file == ".vkey" ]
  firstExceptT ShelleyGenesisCmdReadIndexedVerKeyError $
    Map.fromList <$>
      sequence
        [ (,) ix <$> readKeyFile file
        | (file, ix) <- fileIxs ]
  where
    readKeyFile = newExceptT
                . readFileTextEnvelope (AsVerificationKey AsGenesisDelegateKey)

readDelegateVrfKeys :: FilePath -> ExceptT ShelleyGenesisCmdError IO
                                           (Map Int (VerificationKey VrfKey))
readDelegateVrfKeys deldir = do
  files <- liftIO (listDirectory deldir)
  fileIxs <- extractFileNameIndexes [ deldir </> file
                                    | file <- files
                                    , takeExtensions file == ".vrf.vkey" ]
  firstExceptT ShelleyGenesisCmdReadIndexedVrfKeyError $
    Map.fromList <$>
      sequence
        [ (,) ix <$> readKeyFile file
        | (file, ix) <- fileIxs ]
  where
    readKeyFile = newExceptT
                . readFileTextEnvelope (AsVerificationKey AsVrfKey)


-- | The file path is of the form @"delegate-keys/delegate3.vkey"@.
-- This function reads the file and extracts the index (in this case 3).
--
extractFileNameIndex :: FilePath -> Maybe Int
extractFileNameIndex fp =
  case filter isDigit fp of
    [] -> Nothing
    xs -> readMaybe xs

extractFileNameIndexes :: [FilePath]
                       -> ExceptT ShelleyGenesisCmdError IO [(FilePath, Int)]
extractFileNameIndexes files = do
    case [ file | (file, Nothing) <- filesIxs ] of
      []     -> return ()
      files' -> throwError (ShelleyGenesisFilesNoIndex files')
    case filter (\g -> length g > 1)
       . groupBy ((==) `on` snd)
       . sortBy (compare `on` snd)
       $ [ (file, ix) | (file, Just ix) <- filesIxs ] of
      [] -> return ()
      (g:_) -> throwError (ShelleyGenesisFilesDupIndex (map fst g))

    return [ (file, ix) | (file, Just ix) <- filesIxs ]
  where
    filesIxs = [ (file, extractFileNameIndex file) | file <- files ]

readInitialFundAddresses :: FilePath -> NetworkId
                         -> ExceptT ShelleyGenesisCmdError IO [Address Shelley]
readInitialFundAddresses utxodir nw = do
    files <- liftIO (listDirectory utxodir)
    vkeys <- firstExceptT ShelleyGenesisCmdGenesisUTxOKeyError $
               sequence
                 [ newExceptT $
                     readFileTextEnvelope (AsVerificationKey AsGenesisUTxOKey)
                                          (utxodir </> file)
                 | file <- files
                 , takeExtension file == ".vkey" ]
    return [ addr | vkey <- vkeys
           , let vkh  = verificationKeyHash (castVerificationKey vkey)
                 addr = makeShelleyAddress nw (PaymentCredentialByKey vkh)
                                           NoStakeAddress
           ]
