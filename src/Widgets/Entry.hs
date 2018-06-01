module Widgets.Entry where
import Commons

import Data.Time.Clock (UTCTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Control.Exception (try, SomeException)
import Conduit
import System.FilePath (takeFileName)
import System.Directory (Permissions, getPermissions, readable, writable, executable, searchable,
  getAccessTime, getModificationTime, doesFileExist, getFileSize)
import Brick.Types (Widget)
import Brick.Widgets.Core (vLimit, hBox, str, fill)
import Data.ByteUnits (ByteValue(..), ByteUnit(Bytes), getShortHand, getAppropriateUnits)

data Entry = Dir {name :: String, path :: FilePath, info :: Info} |
  File {name :: String, path :: FilePath, info :: Info} deriving (Ord)
data Info = Info {size :: Size, perms :: Maybe Permissions, times :: Maybe (UTCTime, UTCTime)} deriving (Show, Eq, Ord)
data Size = Waiting | Calculating | Known Integer | Unknown | Avoided deriving (Show, Eq)

instance Show Entry where
  show Dir {name = n} = "+ " ++ n
  show File {name = n} = "- " ++ n

instance Eq Entry where
  Dir {path = p1} == Dir {path = p2} = p1 == p2
  File {path = p1} == File {path = p2} = p1 == p2
  _ == _ = False

instance Ord Size where
  compare (Known a) (Known b) = compare a b
  compare (Known _) _ = GT
  compare _ (Known _) = LT
  compare _ _ = EQ

-- creation functions
make :: FilePath -> IO Entry
make filePath = do
  isFile <- doesFileExist filePath
  if isFile then File (takeFileName filePath) filePath <$> makeInfo filePath True
  else Dir (takeFileName filePath) filePath <$> makeInfo filePath False

makeInfo :: FilePath -> Bool -> IO Info
makeInfo filePath isFile = do
  enSize <- getEntrySize filePath isFile
  enPerms <- toMaybe <$> try (getPermissions filePath)
  enTimes <- toMaybe <$> try (getEntryTimes filePath)
  return $ Info enSize enPerms enTimes

getEntryTimes :: FilePath -> IO (UTCTime, UTCTime)
getEntryTimes filePath = do
  accessTime <- getAccessTime filePath
  modifTime <- getModificationTime filePath
  return (accessTime, modifTime)

makeBackDir :: FilePath -> IO Entry
makeBackDir filePath = do
  enPerms <- toMaybe <$> try (getPermissions filePath)
  enTimes <- toMaybe <$> try (getEntryTimes filePath)
  return $ Dir ".." filePath (Info Avoided enPerms enTimes)

-- rendering functions
render :: Bool -> Entry -> Widget Name
render _ en = let enInfo = info en in vLimit 1 $ hBox [
    str $ show en,
    fill ' ',
    str $ shortSize enInfo,
    renderPerms $ perms enInfo,
    renderTime (times enInfo) False
  ]

renderPerms :: Maybe Permissions -> Widget Name
renderPerms Nothing = str " ----"
renderPerms (Just p) = str [
    ' ',
    if readable p then 'r' else '-',
    if writable p then 'w' else '-',
    if executable p then 'x' else '-',
    if searchable p then 's' else '-'
  ]

renderTime :: Maybe (UTCTime, UTCTime) -> Bool -> Widget Name
renderTime Nothing _ = str " -----------------"
renderTime (Just tms) sel = str . format $ (if sel then fst else snd) tms
  where format = formatTime defaultTimeLocale " %R %b %e %Y"

-- utility functions
toMaybe :: Either SomeException b -> Maybe b
toMaybe = either (const Nothing) Just

isExecutable :: Entry -> Bool
isExecutable = hasPermission executable

isReadable :: Entry -> Bool
isReadable = hasPermission readable

hasPermission :: (Permissions -> Bool) -> Entry -> Bool
hasPermission prop en = case perms $ info en of
  Just enPerms -> prop enPerms
  _ -> False

shortSize :: Info -> String
shortSize enInfo = case size enInfo of
  Known enSize -> getShortHand . getAppropriateUnits $ ByteValue (fromInteger enSize) Bytes
  Unknown -> "???"
  Calculating -> "..."
  Waiting -> "..."
  _ -> ""

notifySize :: FilePath -> Size -> Entry -> Entry
notifySize p s entry
  | p == path entry = entry {info = updateSize s $ info entry}
  | otherwise = entry

updateSize :: Size -> Info -> Info
updateSize s info = info {size = s}

-- directory size function
getEntrySize :: FilePath -> Bool -> IO Size
getEntrySize filePath isFile
  | isFile = toSizeResult <$> try (getFileSize filePath)
  | otherwise = return Waiting

toSizeResult :: Either SomeException Integer -> Size
toSizeResult = either (const Unknown) Known

getDirSize :: FilePath -> IO Integer
getDirSize filePath = runConduitRes
  $ sourceDirectoryDeep False filePath
  .| mapMC (liftIO . getFileSize)
  .| sumC
