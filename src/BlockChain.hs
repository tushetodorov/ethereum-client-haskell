{-# LANGUAGE OverloadedStrings, FlexibleContexts #-}

module BlockChain (
  initializeBlockChain,
  addBlock,
  addBlocks,
  getBestBlock,
  getBestBlockHash
  ) where

import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Resource
import qualified Crypto.Hash.SHA3 as C
import Data.Binary
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Default
import Data.Functor
import qualified Data.Map as M
import Data.Maybe
import Data.Time
import Data.Time.Clock.POSIX
import qualified Database.LevelDB as DB

import Address
import AddressState
import Block
import Code
import Colors
import Constants
import DBs
import Environment
import Format
import ModifyStateDB
import RLP
import SHA
import SignedTransaction
import Storage
import Transaction
import TransactionReceipt
import VM
import VMState

--import Debug.Trace

initializeBlockChain::DB->ResourceT IO ()
initializeBlockChain db = do
  let bytes = rlpSerialize $ rlpEncode genesisBlock
  DB.put (blockDB db) def (C.hash 256 bytes) bytes
  DB.put (detailsDB db) def "best" (BL.toStrict $ encode $ blockHash genesisBlock)

nextDifficulty::Integer->UTCTime->UTCTime->Integer
nextDifficulty oldDifficulty oldTime newTime =
    if (round (utcTimeToPOSIXSeconds newTime)) >=
           (round (utcTimeToPOSIXSeconds oldTime) + 42::Integer)
    then oldDifficulty - oldDifficulty `shiftR` 10
    else oldDifficulty + oldDifficulty `shiftR` 10

nextGasLimit::Integer->Integer->Integer
nextGasLimit oldGasLimit oldGasUsed = max 125000 ((oldGasLimit * 1023 + oldGasUsed *6 `quot` 5) `quot` 1024)

checkUnclesHash::Block->Bool
checkUnclesHash b = (unclesHash $ blockData b) == (hash $ rlpSerialize $ RLPArray (rlpEncode <$> blockUncles b))

--data BlockValidityError = BlockDifficultyWrong Integer Integer | BlockNumberWrong Integer Integer | BlockGasLimitWrong Integer Integer | BlockNonceWrong | BlockUnclesHashWrong
{-
instance Format BlockValidityError where
    --format BlockOK = "Block is valid"
    format (BlockDifficultyWrong d expected) = "Block difficulty is wrong, is '" ++ show d ++ "', expected '" ++ show expected ++ "'"
-}

verifyStateRootExists::DB->Block->ResourceT IO Bool
verifyStateRootExists db b = do
  val <- DB.get (stateDB db) def (BL.toStrict $ encode $ bStateRoot $ blockData b)
  case val of
    Nothing -> return False
    Just _ -> return True

checkParentChildValidity::(Monad m)=>Block->Block->m ()
checkParentChildValidity Block{blockData=c} Block{blockData=p} = do
    unless (difficulty c == nextDifficulty (difficulty p) (timestamp p) ( timestamp c))
             $ fail $ "Block difficulty is wrong: got '" ++ show (difficulty c) ++ "', expected '" ++ show (nextDifficulty (difficulty p) (timestamp p) ( timestamp c)) ++ "'"
    unless (number c == number p + 1) 
             $ fail $ "Block number is wrong: got '" ++ show (number c) ++ ", expected '" ++ show (number p + 1) ++ "'"
    unless (gasLimit c == nextGasLimit (gasLimit p) (gasUsed p))
             $ fail $ "Block gasLimit is wrong: got '" ++ show (gasLimit c) ++ "', expected '" ++ show (nextGasLimit (gasLimit p) (gasUsed p)) ++ "'"
    return ()

checkValidity::Monad m=>DB->Block->ResourceT IO (m ())
checkValidity db b = do
  maybeParentBlock <- getBlock db (parentHash $ blockData b)
  case maybeParentBlock of
    Just parentBlock -> do
          checkParentChildValidity b parentBlock
          unless (nonceIsValid b) $ fail $ "Block nonce is wrong: " ++ format b
          unless (checkUnclesHash b) $ fail "Block unclesHash is wrong"
          stateRootExists <- verifyStateRootExists db b
          unless stateRootExists $ fail ("Block stateRoot does not exist: " ++ format (bStateRoot $ blockData b))
          return $ return ()
    Nothing -> fail ("Parent Block does not exist: " ++ format (parentHash $ blockData b))


{-
                    coinbase=prvKey2Address prvKey,
        stateRoot = SHA 0x9b109189563315bfeb13d4bfd841b129ff3fd5c85f228a8d9d8563b4dde8432e,
                    transactionsTrie = 0,
-}


pay::DB->Address->Address->Integer->ResourceT IO DB
pay db fromAddr toAddr val = do
  db' <- addToBalance db fromAddr (-val)
  addToBalance db' toAddr val

runCodeForTransaction::DB->Block->SignedTransaction->ResourceT IO DB
runCodeForTransaction db b t@SignedTransaction{unsignedTransaction=ut} = do
  let tAddr = whoSignedThisTransaction t

  let intrinsicGas = 5*(fromIntegral $ codeLength $ tInit ut) + 500

  liftIO $ putStrLn $ "intrinsicGas: " ++ show intrinsicGas
  
  --TODO- return here if not enough gas
  
  db2 <- pay db tAddr (coinbase $ blockData b) (intrinsicGas * gasPrice ut)

  case tInit ut of
    Code x | B.null x -> return db2
    theCode -> do
      let availableGas = tGasLimit ut - intrinsicGas
      liftIO $ putStrLn $ "availableGas: " ++ show availableGas

      vmState <- 
        liftIO $ runCodeFromStart db2 availableGas
          Environment{
            envGasPrice=gasPrice ut,
            envBlock=b,
            envOwner = tAddr,
            envOrigin = undefined,
            envInputData = undefined,
            envSender = undefined,
            envValue = undefined,
            envCode = tInit ut
            }
  
      liftIO $ putStrLn $ "gasRemaining: " ++ show (vmGasRemaining vmState)
      let usedGas = availableGas - vmGasRemaining vmState
      liftIO $ putStrLn $ "gasUsed: " ++ show usedGas
      db3 <- pay db2 tAddr (coinbase $ blockData b) (usedGas * gasPrice ut)


      case vmException vmState of
        Just e -> do
          liftIO $ putStrLn $ red $ show e
          return db3
        Nothing -> do
          result <- liftIO $ getReturnValue vmState
          liftIO $ putStrLn $ "Result: " ++ show result
          let newAddress = getNewAddress t
          liftIO $ putStrLn $ format newAddress ++ ": " ++ format result
          --TODO- I think there is an error in the cpp ethereum, no new account is made
          --when value doesn't equal 0....  I am mimicking this here so that I can work with that
          --client, but I really should either try to understand this better or if I convince myself
          --that there is a bug, report it.
          if value ut == 0 || not (M.null $ storage vmState)
            then do
            storageDB <- addStorageToDB db3 $ storage vmState
            db4 <- putAddressState db3 newAddress
                   AddressState{
                     addressStateNonce=0,
                     balance=0,
                     contractRoot=if (M.null $ storage vmState)
                                  then Nothing
                                  else Just $ stateRoot storageDB,
                     codeHash=hash result
                     }
            pay db4 tAddr newAddress (value ut)
            else return db3

addBlocks::DB->[Block]->ResourceT IO ()
addBlocks db blocks = do
  forM_ blocks $ addBlock db

getNewAddress::SignedTransaction->Address
getNewAddress t =
  let theHash = hash $ rlpSerialize $ RLPArray [rlpEncode $ whoSignedThisTransaction t, rlpEncode $ tNonce $ unsignedTransaction t]
  in decode $ BL.drop 12 $ encode $ theHash

isTransactionValid::DB->SignedTransaction->ResourceT IO Bool
isTransactionValid db t = do
  maybeAddressState <- getAddressState db $ whoSignedThisTransaction t
  case maybeAddressState of
    Nothing -> return (0 == tNonce (unsignedTransaction t))
    Just addressState -> return (addressStateNonce addressState == tNonce (unsignedTransaction t))

addTransaction::DB->Block->SignedTransaction->ResourceT IO DB
addTransaction db b t = do
  liftIO $ putStrLn "adding to nonces"
  let signAddress = whoSignedThisTransaction t
  db2 <- addNonce db signAddress
  liftIO $ putStrLn "paying value to recipient"
  db3 <- if to (unsignedTransaction t) == Address 0
         then return db2 --addToBalance db2 signAddress (-value (unsignedTransaction t))
         else transferEther db2 signAddress (to $ unsignedTransaction t) (value (unsignedTransaction t))
  liftIO $ putStrLn "running code"
  runCodeForTransaction db3 b t

addTransactions::DB->Block->[SignedTransaction]->ResourceT IO DB
addTransactions db _ [] = return db
addTransactions db b (t:rest) = do
  valid <- isTransactionValid db t
  db' <- if valid
         then addTransaction db b t
         else return db
  addTransactions db' b rest
  

addBlock::DB->Block->ResourceT IO ()
addBlock db b = do
  let bd = blockData b
  parentBlock <-
    fromMaybe (error ("Missing parent block in addBlock: " ++ format (parentHash bd))) <$>
    (getBlock db $ parentHash bd)

  db2 <- addToBalance db{stateRoot=bStateRoot $ blockData parentBlock} (coinbase bd) (1500*finney)

  let transactions = theTransaction <$> receiptTransactions b

  db3 <- addTransactions db2 b transactions
  

  liftIO $ putStrLn $ "newStateRoot: " ++ format (stateRoot db3)

  valid <- checkValidity db b
  case valid of
     Right () -> return ()
     Left err -> error err
  let bytes = rlpSerialize $ rlpEncode b
  DB.put (blockDB db) def (C.hash 256 bytes) bytes
  replaceBestIfBetter db b

getBestBlockHash::DB->ResourceT IO (Maybe SHA)
getBestBlockHash db = do
  fmap (decode . BL.fromStrict) <$> DB.get (detailsDB db) def "best"

getBlock::DB->SHA->ResourceT IO (Maybe Block)
getBlock db h = 
  fmap (rlpDecode . rlpDeserialize) <$> DB.get (blockDB db) def (BL.toStrict $ encode h)

getBestBlock::DB->ResourceT IO (Maybe Block)
getBestBlock db = do
  maybeH <- getBestBlockHash db
  case maybeH of
    Nothing -> return Nothing
    Just h -> getBlock db h

replaceBestIfBetter::DB->Block->ResourceT IO ()
replaceBestIfBetter db b = do
  maybeBest <- getBestBlock db
  case maybeBest of
    Just best | number (blockData best) >= number (blockData b) -> return ()
    _ -> runResourceT $ do
      DB.put (detailsDB db) def "best" (BL.toStrict $ encode $ blockHash b)

