{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE GADTs              #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications   #-}

{-# OPTIONS_GHC -Wno-orphans #-}

module Test.Consensus.Byron.Generators (
    epochSlots
  , protocolMagicId
  , RegularBlock (..)
  ) where

import           Data.Coerce (coerce)
import           Data.Proxy

import           Cardano.Binary (fromCBOR, toCBOR)
import           Cardano.Chain.Block (ABlockOrBoundary (..),
                     ABlockOrBoundaryHdr (..))
import qualified Cardano.Chain.Block as CC.Block
import qualified Cardano.Chain.Byron.API as API
import           Cardano.Chain.Common (BlockCount (..), KeyHash)
import qualified Cardano.Chain.Delegation as CC.Del
import qualified Cardano.Chain.Delegation.Validation.Activation as CC.Act
import qualified Cardano.Chain.Delegation.Validation.Interface as CC.DI
import qualified Cardano.Chain.Delegation.Validation.Scheduling as CC.Sched
import qualified Cardano.Chain.Genesis as CC.Genesis
import           Cardano.Chain.Slotting (EpochNumber, EpochSlots (..),
                     SlotNumber)
import qualified Cardano.Chain.Update as CC.Update
import qualified Cardano.Chain.Update.Validation.Interface as CC.UPI
import qualified Cardano.Chain.UTxO as CC.UTxO
import           Cardano.Crypto (ProtocolMagicId (..))
import           Cardano.Crypto.Hashing (Hash)

import           Ouroboros.Network.Block (BlockNo (..), SlotNo (..))
import           Ouroboros.Network.Point (WithOrigin (..), withOrigin)

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Config.SecurityParam
import           Ouroboros.Consensus.HeaderValidation (AnnTip (..))
import           Ouroboros.Consensus.Ledger.SupportsMempool (GenTxId)
import           Ouroboros.Consensus.Protocol.PBFT.State (PBftState)
import qualified Ouroboros.Consensus.Protocol.PBFT.State as PBftState
import qualified Ouroboros.Consensus.Protocol.PBFT.State.HeaderHashBytes as PBftState

import           Ouroboros.Consensus.Byron.Ledger
import qualified Ouroboros.Consensus.Byron.Ledger.DelegationHistory as DH
import           Ouroboros.Consensus.Byron.Protocol

import           Test.QuickCheck hiding (Result)
import           Test.QuickCheck.Hedgehog (hedgehog)

import qualified Test.Cardano.Chain.Block.Gen as CC
import qualified Test.Cardano.Chain.Common.Gen as CC
import qualified Test.Cardano.Chain.Delegation.Gen as CC
import qualified Test.Cardano.Chain.MempoolPayload.Gen as CC
import qualified Test.Cardano.Chain.Slotting.Gen as CC
import qualified Test.Cardano.Chain.Update.Gen as UG
import qualified Test.Cardano.Chain.UTxO.Gen as CC
import qualified Test.Cardano.Crypto.Gen as CC

import           Test.Util.Orphans.Arbitrary ()
import           Test.Util.Serialisation (SomeResult (..), WithVersion (..))

{-------------------------------------------------------------------------------
  Generators
-------------------------------------------------------------------------------}

-- | Matches that from the 'CC.dummyConfig'
k :: SecurityParam
k = SecurityParam 10

-- | Matches that from the 'CC.dummyConfig'
epochSlots :: EpochSlots
epochSlots = EpochSlots 100

protocolMagicId :: ProtocolMagicId
protocolMagicId = ProtocolMagicId 100

-- | A 'ByronBlock' that is never an EBB.
newtype RegularBlock = RegularBlock { unRegularBlock :: ByronBlock }
  deriving (Eq, Show)

instance Arbitrary RegularBlock where
  arbitrary =
    RegularBlock .annotateByronBlock epochSlots <$>
    hedgehog (CC.genBlock protocolMagicId epochSlots)

instance Arbitrary ByronBlock where
  arbitrary = frequency
      [ (3, genBlock)
      , (1, genBoundaryBlock)
      ]
    where
      genBlock :: Gen ByronBlock
      genBlock = unRegularBlock <$> arbitrary
      genBoundaryBlock :: Gen ByronBlock
      genBoundaryBlock =
        mkByronBlock epochSlots . ABOBBoundary . API.reAnnotateBoundary protocolMagicId <$>
        hedgehog (CC.genBoundaryBlock)

instance Arbitrary (Header ByronBlock) where
  arbitrary = frequency
      [ (3, genHeader)
      , (1, genBoundaryHeader)
      ]
    where
      genHeader :: Gen (Header ByronBlock)
      genHeader = do
        blockSize <- arbitrary
        flip (mkByronHeader epochSlots) blockSize . ABOBBlockHdr .
          API.reAnnotateUsing
            (CC.Block.toCBORHeader epochSlots)
            (CC.Block.fromCBORAHeader epochSlots) <$>
          hedgehog (CC.genHeader protocolMagicId epochSlots)

      genBoundaryHeader :: Gen (Header ByronBlock)
      genBoundaryHeader = do
        blockSize <- arbitrary
        flip (mkByronHeader epochSlots) blockSize . ABOBBoundaryHdr .
          API.reAnnotateUsing
            (CC.Block.toCBORABoundaryHeader protocolMagicId)
            CC.Block.fromCBORABoundaryHeader <$>
          hedgehog CC.genBoundaryHeader

instance Arbitrary (Hash a) where
  arbitrary = coerce <$> hedgehog CC.genTextHash

instance Arbitrary ByronHash where
  arbitrary = ByronHash <$> arbitrary

instance Arbitrary KeyHash where
  arbitrary = hedgehog CC.genKeyHash

instance Arbitrary (GenTx ByronBlock) where
  arbitrary =
    fromMempoolPayload . API.reAnnotateUsing toCBOR fromCBOR <$>
    hedgehog (CC.genMempoolPayload protocolMagicId)

instance Arbitrary (GenTxId ByronBlock) where
  arbitrary = oneof
      [ ByronTxId             <$> hedgehog CC.genTxId
      , ByronDlgId            <$> hedgehog genCertificateId
      , ByronUpdateProposalId <$> hedgehog (UG.genUpId protocolMagicId)
      , ByronUpdateVoteId     <$> hedgehog genUpdateVoteId
      ]
    where
      genCertificateId = CC.genAbstractHash (CC.genCertificate protocolMagicId)
      genUpdateVoteId  = CC.genAbstractHash (UG.genVote protocolMagicId)

instance Arbitrary API.ApplyMempoolPayloadErr where
  arbitrary = oneof
    [ API.MempoolTxErr  <$> hedgehog CC.genUTxOValidationError
    , API.MempoolDlgErr <$> hedgehog CC.genError
    -- TODO there is no generator for
    -- Cardano.Chain.Update.Validation.Interface.Error and we can't write one
    -- either because the different Error types it wraps are not exported.
    -- , MempoolUpdateProposalErr <$> arbitrary
    -- , MempoolUpdateVoteErr     <$> arbitrary
    ]

instance Arbitrary (SomeBlock Query ByronBlock) where
  arbitrary = pure $ SomeBlock GetUpdateInterfaceState

instance Arbitrary EpochNumber where
  arbitrary = hedgehog CC.genEpochNumber

instance Arbitrary SlotNumber where
  arbitrary = hedgehog CC.genSlotNumber

instance Arbitrary CC.Update.ApplicationName where
  arbitrary = hedgehog UG.genApplicationName

instance Arbitrary CC.Update.SystemTag where
  arbitrary = hedgehog UG.genSystemTag

instance Arbitrary CC.Update.InstallerHash where
  arbitrary = hedgehog UG.genInstallerHash

instance Arbitrary CC.Update.ProtocolVersion where
  arbitrary = hedgehog UG.genProtocolVersion

instance Arbitrary CC.Update.ProtocolParameters where
  arbitrary = hedgehog UG.genProtocolParameters

instance Arbitrary CC.Update.SoftwareVersion where
  arbitrary = hedgehog UG.genSoftwareVersion

instance Arbitrary CC.UPI.State where
  arbitrary = CC.UPI.State
    <$> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> pure mempty -- TODO CandidateProtocolUpdate's constructor is not exported
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> pure mempty -- TODO Endorsement is not exported
    <*> arbitrary

instance Arbitrary CC.Genesis.GenesisHash where
  arbitrary = CC.Genesis.GenesisHash <$> arbitrary

instance Arbitrary CC.UTxO.UTxO where
  arbitrary = hedgehog CC.genUTxO

instance Arbitrary CC.Act.State where
  arbitrary = CC.Act.State
    <$> arbitrary
    <*> arbitrary

instance Arbitrary CC.Sched.ScheduledDelegation where
  arbitrary = CC.Sched.ScheduledDelegation
    <$> arbitrary
    <*> arbitrary
    <*> arbitrary

instance Arbitrary CC.Sched.State where
  arbitrary = CC.Sched.State
    <$> arbitrary
    <*> arbitrary

instance Arbitrary CC.DI.State where
  arbitrary = CC.DI.State
    <$> arbitrary
    <*> arbitrary

instance Arbitrary CC.Block.ChainValidationState where
  arbitrary = CC.Block.ChainValidationState
    <$> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary
    <*> arbitrary

instance Arbitrary ByronNodeToNodeVersion where
  arbitrary = arbitraryBoundedEnum

instance Arbitrary ByronNodeToClientVersion where
  arbitrary = arbitraryBoundedEnum

instance Arbitrary CC.Del.Map where
  arbitrary = CC.Del.fromList <$> arbitrary

instance Arbitrary DelegationHistory where
  arbitrary = do
      steps <- choose (0, 5)
      go steps (SlotNo 0) DH.empty
    where
      go :: Int
         -> SlotNo
         -> DelegationHistory
         -> Gen DelegationHistory
      go steps prevSlot st
        | 0 <- steps = return st
        | otherwise  = do
          slot <- ((prevSlot +) . SlotNo) <$> choose (1, 5)
          delMap <- arbitrary
          go (steps - 1) slot (DH.snapOld (BlockCount 10) slot delMap st)

instance Arbitrary (LedgerState ByronBlock) where
  arbitrary = ByronLedgerState <$> arbitrary <*> arbitrary

instance Arbitrary (AnnTip ByronBlock) where
  arbitrary = AnnTip
    <$> arbitrary
    <*> (BlockNo <$> arbitrary)
    <*> ((,) <$> arbitrary <*> elements [IsEBB, IsNotEBB])

instance Arbitrary (PBftState PBftByronCrypto) where
  arbitrary = do
      steps <- choose (0, 5)
      go steps Origin PBftState.empty
    where
      go :: Int
         -> WithOrigin SlotNo
         -> PBftState PBftByronCrypto
         -> Gen (PBftState PBftByronCrypto)
      go steps prevSlot st
        | 0 <- steps = return st
        | otherwise  = do
          let slot = withOrigin (SlotNo 0) succ prevSlot
          ebb <- arbitrary
          st' <-
            if ebb then do
              headerHashBytes <-
                PBftState.headerHashBytes (Proxy @ByronBlock) <$> arbitrary
              return $ PBftState.appendEBB k windowSize slot headerHashBytes st
            else do
              newSigner <- PBftState.PBftSigner slot <$> arbitrary
              return $ PBftState.append k windowSize newSigner st
          go (steps - 1) (At slot) st'

      windowSize = PBftState.WindowSize (maxRollbacks k)

instance Arbitrary (SomeResult ByronBlock) where
  arbitrary = SomeResult GetUpdateInterfaceState  <$> arbitrary

{-------------------------------------------------------------------------------
  Versioned generators for serialisation
-------------------------------------------------------------------------------}

-- | We only have to be careful about headers with ByronNodeToNodeVersion1,
-- where we will have a fake block size hint.
instance Arbitrary (WithVersion ByronNodeToNodeVersion (Header ByronBlock)) where
  arbitrary = do
    version <- arbitrary
    hdr     <- arbitrary
    let hdr' = case version of
          ByronNodeToNodeVersion1 ->
            hdr { byronHeaderBlockSizeHint = fakeByronBlockSizeHint }
          ByronNodeToNodeVersion2 ->
            hdr
    return (WithVersion version hdr')

instance Arbitrary (WithVersion ByronNodeToNodeVersion (SomeBlock (NestedCtxt Header) ByronBlock)) where
  arbitrary = do
      version <- arbitrary
      size    <- case version of
                   ByronNodeToNodeVersion1 -> return fakeByronBlockSizeHint
                   ByronNodeToNodeVersion2 -> arbitrary
      ctxt    <- elements [
                     SomeBlock . NestedCtxt $ CtxtByronRegular  size
                   , SomeBlock . NestedCtxt $ CtxtByronBoundary size
                   ]
      return (WithVersion version ctxt)

-- | All other types are unaffected by the versioning for
-- 'ByronNodeToNodeVersion'.
instance {-# OVERLAPPABLE #-} Arbitrary a
      => Arbitrary (WithVersion ByronNodeToNodeVersion a) where
  arbitrary = WithVersion <$> arbitrary <*> arbitrary

-- | No types are affected by the versioning for
-- 'ByronNodeToClientVersion'.
instance Arbitrary a => Arbitrary (WithVersion ByronNodeToClientVersion a) where
  arbitrary = WithVersion <$> arbitrary <*> arbitrary
