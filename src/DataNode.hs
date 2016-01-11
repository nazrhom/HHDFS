module DataNode where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import qualified Data.ByteString.Lazy as B
import System.Directory (doesFileExist, removeFile)
import Control.Monad (when, forever)

import Messages

dataNode :: ProcessId -> Process ()
dataNode nnid = do
  pid <- getSelfPid
  send nnid $ HandShake pid

  handleMessages


handleMessages :: Process ()
handleMessages = forever $ do
  msg <- expect
  case msg of
    CDNRead bid sendPort -> do
      file <- liftIO $ B.readFile (getFileName bid)
      sendChan sendPort file
    CDNWrite bid file ->
      liftIO $ B.writeFile (getFileName bid) file
    CDNDelete bid -> liftIO $ do
      let fileName = getFileName bid
      fileExists <- doesFileExist fileName
      when fileExists $ removeFile (getFileName bid)

getFileName :: BlockId -> FilePath
getFileName bid = "./data/" ++ show bid ++ ".dat"
