{-# LANGUAGE RecordWildCards, ScopedTypeVariables #-}

module NameNode where

import            Control.Distributed.Process
import            Control.Concurrent (threadDelay)
import            System.FilePath (takeFileName, isValid)
import            Data.Map (Map)
import qualified  Data.Map as M
import            Control.Monad (unless)
import qualified  Data.Set as S
import            Data.Char (ord)

import            Data.Maybe (fromJust, mapMaybe, fromMaybe)
import            Data.Binary (encodeFile, decodeFile)
import            System.Directory (doesFileExist, createDirectoryIfMissing)

import            Messages

repFactor :: Int
repFactor = 2

type FsImage = Map FilePath [BlockId]
type BlockMap = Map BlockId (S.Set DataNodeId)
type DataNodeIdPidMap = Map DataNodeId ProcessId


data NameNode = NameNode
  { dataNodes :: [DataNodeId]
  , fsImage :: FsImage
  , dnIdPidMap :: DataNodeIdPidMap
  , blockMap :: BlockMap
  , repMap :: BlockMap
  }

nnConfDir, nnDataDir, fsImageFile, dnMapFile, blockMapFile :: String
nnConfDir = "./nn_conf/"
nnDataDir = "./nn_data/"
fsImageFile = nnDataDir ++ "fsImage.fs"
dnMapFile = nnDataDir ++ "dn_map.map"
blockMapFile = nnDataDir ++ "block_map.map"


nameNode :: Process ()
nameNode = do
  liftIO $ createDirectoryIfMissing False nnDataDir
  dnMap <- liftIO readDnMap
  fsImg <- liftIO readFsImage
  blockMap <- liftIO readBlockMap
  loop (NameNode [] fsImg dnMap blockMap M.empty)
  where
    loop nnode = receiveWait
      [ match $ \(clientReq :: ClientReq) -> handleMatch handleClients clientReq
      , match $ \(handShake :: HandShake) -> handleMatch handleDataNodes handShake
      , match $ \(blockreport :: BlockReport) -> handleMatch handleBlockReport blockreport
      ]
      where handleMatch handler req = handler nnode req >>= loop

handleDataNodes :: NameNode -> HandShake -> Process NameNode
handleDataNodes nameNode@NameNode{..} (HandShake pid dnId bids) = do
  let newMap = M.insert dnId pid dnIdPidMap
      dnIdSet = S.singleton dnId --Share this set
      bidMap = M.fromList $ map (\x -> (x,dnIdSet)) bids --make tuples of a blockId and the dnIdSet,
                                                         --then use that to construct a Map
      newBlockMap = M.unionWith S.union blockMap bidMap --Add all blockId's of the current DataNode to the BlockMap
  liftIO $ flushDnMap newMap
  return $ nameNode { dataNodes = dnId:dataNodes, dnIdPidMap = newMap, blockMap = newBlockMap }

handleDataNodes nameNode@NameNode{..} (WhoAmI chan) = do
  sendChan chan $ nextDnId (M.keys dnIdPidMap)
  return nameNode
  where
    nextDnId [] = 0
    nextDnId a = maximum a + 1

handleClients :: NameNode -> ClientReq -> Process NameNode
handleClients nameNode@NameNode{..} (Write fp blockCount chan) =
  if not $ isValid fp
  then do
    sendChan chan (Left InvalidPathError)
    return nameNode
  else do
    let
      dnodePids = mapMaybe (`M.lookup` dnIdPidMap) dataNodes
      selectedDnodes = take blockCount $ map (toPid dnodePids (takeFileName fp)) [0..]
      positions = zip selectedDnodes [(length $ M.keys blockMap)..]
      newfsImage = M.insert fp (map snd positions) fsImage
    sendChan chan (Right positions)
    liftIO $ flushFsImage newfsImage

    return $ nameNode
        { fsImage = newfsImage }

handleClients nameNode@NameNode{..} (Read fp chan) = do
  case M.lookup fp fsImage of
    Nothing -> sendChan chan (Left FileNotFound)
    Just bids -> do
      --We can either lookup twice or lookup once after a union
      --let mpids = M.lookup bid (M.unionWith S.union blockMap repMap)
      let mpids = map (\bid -> (head $ S.toList $ fromJust $ M.lookup bid $ M.unionWith S.union blockMap repMap, bid)) bids
      let res = map (\(dnodeId, bid) -> (fromJust $ M.lookup dnodeId dnIdPidMap, bid)) mpids
      sendChan chan (Right res)
  return nameNode

handleClients nameNode@NameNode{..} (ListFiles chan) = do
  sendChan chan (M.keys fsImage)
  return nameNode

handleClients NameNode{..} Shutdown = do
  mapM_ (`kill` "User shutdown") (mapMaybe toPid dataNodes)
  liftIO (threadDelay 20000)
  terminate
    where
      toPid dnodeId = M.lookup dnodeId dnIdPidMap


--Whenever we receive a blockreport from a datanode we will have to update
--the repmap and the blockmap.
handleBlockReport :: NameNode -> BlockReport -> Process NameNode
handleBlockReport nameNode@NameNode{..} (BlockReport dnodeId blocks) = do
  --First we have to determine whether to add a block to BlockMap or RepMap. If the block
  --already exists in the RepMap, then we add the ProcessId to the corresponding set. If not,
  --we try the same for the BlockMap. If it exists in neither then it has to be a new BlockId
  --and therefore we add it to the BlockMap
  let foldBlocks x (bl,rep) = case (M.member x rep, M.member x bl) of
        (True, _)  -> (bl                                 , M.adjust (S.insert dnodeId) x rep)
        (_, True)  -> (M.adjust (S.insert dnodeId) x bl   , rep                              )
        (_, False) -> (M.insert x (S.singleton dnodeId) bl, rep                              )

      (blockmap,repmap) = foldr foldBlocks (blockMap,repMap) blocks
      --We are done with incorporating the blockreport into the maps, but we possibly have to move
      --entries from the repmap to the blockmap and vica versa.
      --First we partition both maps on how many ProcessId's contain a BlockId
      (toblmap,repmap') = M.partition (\x -> S.size x >= repFactor + 1) repmap
      (torepmap,blockmap') = M.partition (\x -> S.size x <= repFactor) blockmap
      --Next we union the results
      newBlMap = M.unionWith S.union toblmap blockmap'
      newRepMap = M.unionWith S.union torepmap repmap'
  --Any BlockId's that were moved from the blockmap to the replicationmap have to be replicated.
  --For any BlockId that has to be replicated we select the replication factor - the number of
  --datanodes that already have that BlockId + 1 for the dataNode that sent this blockreport, afterwards
  --we send a Replication request to the `current` dataNode to send that BlockId to the selected dataNodes
      pid = fromMaybe (error "This should not happen") $ M.lookup dnodeId dnIdPidMap

      --Simple method for selecting datanodes that we want to replicate to
      selectDataNodes :: Int  -> [DataNodeId] -> [ProcessId]
      selectDataNodes n dataNodes = take n $ filter (/= pid) dataNodesPids
        where
          dataNodesPids = mapMaybe (`M.lookup` dnIdPidMap) dataNodes

  mapM_ (\(k,a) -> send pid $ CDNRep k $
                    selectDataNodes (repFactor - S.size a + 1) dataNodes)
                                                        (M.toList torepmap)
  return $ nameNode { blockMap = newBlMap, repMap = newRepMap}


------- UTILITY ------

-- Another naive implementation to find the next free block id given a datanode
-- This should be changed to something more robust and performant
nextBidFor :: DataNodeId -> [LocalPosition] -> BlockId
nextBidFor _   []        = 0
nextBidFor pid positions = maximum (map toBid positions) + 1
  where
    toBid (nnodePid, blockId) | nnodePid == pid = blockId
                              | otherwise       = 0

-- For the time being we can pick the dataNode where to store a file with this
-- naive technique.
toPid :: [ProcessId] -> String -> Int -> ProcessId
toPid pids s bix = pids !! ((ord (head s) + bix) `mod` length pids)


flushFsImage :: FsImage -> IO ()
flushFsImage = encodeFile fsImageFile

readFsImage :: IO FsImage
readFsImage = do
  fileExist <- liftIO $ doesFileExist fsImageFile
  unless fileExist $ flushFsImage M.empty
  decodeFile fsImageFile

flushBlockMap :: BlockMap -> IO ()
flushBlockMap = encodeFile blockMapFile

readBlockMap :: IO BlockMap
readBlockMap = do
  fileExist <- liftIO $ doesFileExist blockMapFile
  unless fileExist $ flushBlockMap M.empty
  decodeFile blockMapFile

flushDnMap :: DataNodeIdPidMap -> IO ()
flushDnMap = encodeFile dnMapFile

readDnMap :: IO DataNodeIdPidMap
readDnMap = do
  fileExist <- liftIO $ doesFileExist dnMapFile
  unless fileExist $ liftIO $ flushDnMap M.empty
  decodeFile dnMapFile
