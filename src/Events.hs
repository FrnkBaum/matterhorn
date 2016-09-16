module Events where

import           Brick
import           Brick.Widgets.Edit ( getEditContents
                                    , handleEditorEvent
                                    , applyEdit
                                    )
import           Brick.Widgets.List (handleListEvent, listSelectedElement)
import           Control.Monad ((>=>))
import           Control.Monad.IO.Class (liftIO)
import           Data.Maybe (listToMaybe)
import qualified Data.Set as Set
import           Data.Text.Zipper ( TextZipper
                                  , getText
                                  , clearZipper
                                  , insertMany
                                  , deletePrevChar )
import qualified Data.Text as T
import Data.Monoid ((<>))
import qualified Graphics.Vty as Vty
import           Lens.Micro.Platform
import qualified Codec.Binary.UTF8.Generic as UTF8

import           Network.Mattermost
import           Network.Mattermost.Lenses
import           Network.Mattermost.WebSocket.Types

import           Command
import           Connection
import           Completion
import           State
import           Types
import           InputHistory

onEvent :: ChatState -> Event -> EventM Name (Next ChatState)
onEvent st RefreshWebsocketEvent = do
  liftIO $ connectWebsockets st
  msg <- newClientMessage Informative "Websocket connecting..."
  continue =<< addClientMessage msg st
onEvent st WebsocketDisconnect = do
  msg <- newClientMessage Informative "Websocket disconnected."
  continue =<< (addClientMessage msg $ st & csConnectionStatus .~ Disconnected)
onEvent st WebsocketConnect = do
  msg <- newClientMessage Informative "Websocket reconnected."
  continue =<< (addClientMessage msg $ st & csConnectionStatus .~ Connected)
onEvent st (WSEvent we) =
  handleWSEvent st we
onEvent st (RespEvent f) =
  continue =<< f st
onEvent st (VtyEvent e) = do
    case st^.csMode of
        Main                -> onEventMain st e
        ShowHelp            -> onEventShowHelp st e
        ChannelSelect       -> onEventChannelSelect st e
        LeaveChannelConfirm -> onEventLeaveChannelConfirm st e
        JoinChannel         -> onEventJoinChannel st e

onEventShowHelp :: ChatState -> Vty.Event -> EventM Name (Next ChatState)
onEventShowHelp st e | Just kb <- lookupKeybinding e helpKeybindings = kbAction kb st
onEventShowHelp st (Vty.EvKey _ _) = do
  continue $ st & csMode .~ Main
onEventShowHelp st _ = continue st

onEventMain :: ChatState -> Vty.Event -> EventM Name (Next ChatState)
onEventMain st (Vty.EvResize _ _) = do
  -- On resize we need to update the current channel message area so
  -- that the most recent message is at the bottom. We have to do this
  -- on a resize because brick only guarantees that the message is
  -- visible, not that it is at the bottom, so after a resize we can end
  -- up with lots of whitespace at the bottom of the message area. This
  -- whitespace is created when the window gets bigger. We only need to
  -- worry about the current channel's viewport because that's the one
  -- that is about to be redrawn.
  continue =<< updateChannelScrollState st
onEventMain st e | Just kb <- lookupKeybinding e mainKeybindings = kbAction kb st
onEventMain st (Vty.EvPaste bytes) = do
  -- If you paste a multi-line thing, it'll only insert up to the first
  -- line ending because the zipper will respect the line limit when
  -- inserting the paste. Once we add support for multi-line editing,
  -- this will Just Work once the editor's line limit is set to Nothing.
  let pasteStr = T.pack (UTF8.toString bytes)
  continue $ st & cmdLine %~ applyEdit (insertMany pasteStr)
onEventMain st e = do
  continue =<< handleEventLensed (st & csCurrentCompletion .~ Nothing) cmdLine handleEditorEvent e

joinChannelListKeys :: [Vty.Key]
joinChannelListKeys =
    [ Vty.KUp
    , Vty.KDown
    , Vty.KPageUp
    , Vty.KPageDown
    , Vty.KHome
    , Vty.KEnd
    ]

onEventJoinChannel :: ChatState -> Vty.Event -> EventM Name (Next ChatState)
onEventJoinChannel st e@(Vty.EvKey k []) | k `elem` joinChannelListKeys = do
    result <- case st^.csJoinChannelList of
        Nothing -> return Nothing
        Just l -> Just <$> handleListEvent e l
    continue $ st & csJoinChannelList .~ result
onEventJoinChannel st (Vty.EvKey Vty.KEnter []) = do
    case st^.csJoinChannelList of
        Nothing -> continue st
        Just l -> case listSelectedElement l of
            Nothing -> continue st
            Just (_, chan) -> joinChannel chan st >>= continue
onEventJoinChannel st (Vty.EvKey Vty.KEsc []) = do
    continue $ st & csMode .~ Main
onEventJoinChannel st _ = do
    continue st

onEventLeaveChannelConfirm :: ChatState -> Vty.Event -> EventM Name (Next ChatState)
onEventLeaveChannelConfirm st (Vty.EvKey k []) = do
    st' <- case k of
        Vty.KChar c | c `elem` ("yY"::String) ->
            leaveCurrentChannel st
        _ -> return st
    continue $ st' & csMode .~ Main
onEventLeaveChannelConfirm st _ = do
    continue st

onEventChannelSelect :: ChatState -> Vty.Event -> EventM Name (Next ChatState)
onEventChannelSelect st e | Just kb <- lookupKeybinding e channelSelectKeybindings = kbAction kb st
onEventChannelSelect st (Vty.EvKey Vty.KBS []) = do
    continue $ st & csChannelSelect %~ (\s -> if T.null s then s else T.init s)
onEventChannelSelect st (Vty.EvKey (Vty.KChar c) []) | c /= '\t' = do
    continue $ st & csChannelSelect %~ (flip T.snoc c)
onEventChannelSelect st _ = do
    continue st

-- XXX: killWordBackward, and delete could probably all
-- be moved to the text zipper package (after some generalization and cleanup)
-- for example, we should look up the standard unix word break characters
-- and use those in killWordBackward.
killWordBackward :: TextZipper T.Text -> TextZipper T.Text
killWordBackward z =
    let n = T.length
          $ T.takeWhile (/= ' ')
          $ T.reverse line
        delete n' z' | n' <= 0 = z'
        delete n' z' = delete (n'-1) (deletePrevChar z')
        (line:_) = getText z
    in delete n z

tabComplete :: Completion.Direction
            -> ChatState -> EventM Name (Next ChatState)
tabComplete dir st = do
  let priorities  = [] :: [T.Text]-- XXX: add recent completions to this
      completions = Set.fromList (st^.csNames.cnUsers ++
                                  st^.csNames.cnChans ++
                                  map ("@" <>) (st^.csNames.cnUsers) ++
                                  map ("#" <>) (st^.csNames.cnChans) ++
                                  map ("/" <>) (map commandName commandList))

      (line:_)    = getEditContents (st^.cmdLine)
      curComp     = st^.csCurrentCompletion
      (nextComp, alts) = case curComp of
          Nothing -> let cw = currentWord line
                     in (Just cw, filter (cw `T.isPrefixOf`) $ Set.toList completions)
          Just cw -> (Just cw, filter (cw `T.isPrefixOf`) $ Set.toList completions)

      mb_word     = wordComplete dir priorities completions line curComp
      st' = st & csCurrentCompletion .~ nextComp
               & csEditState.cedCompletionAlternatives .~ alts
      (edit, curAlternative) = case mb_word of
          Nothing -> (id, "")
          Just w -> (insertMany w . killWordBackward, w)

  continue $ st' & cmdLine %~ (applyEdit edit)
                 & csEditState.cedCurrentAlternative .~ curAlternative

handleWSEvent :: ChatState -> WebsocketEvent -> EventM Name (Next ChatState)
handleWSEvent st we =
  case weEvent we of
    WMPosted -> case wepPost (weData we) of
      Just p  -> addMessage p st >>= continue
      Nothing -> continue st
    WMPostEdited -> case wepPost (weData we) of
      Just p  -> editMessage p st >>= continue
      Nothing -> continue st
    WMPostDeleted -> case wepPost (weData we) of
      Just p  -> deleteMessage p st >>= continue
      Nothing -> continue st
    WMStatusChange -> case wepStatus (weData we) of
      Just status -> updateStatus (weUserId we) status st >>= continue
      Nothing -> continue st
    WMChannelViewed -> case wepChannelId (weData we) of
      Just cId -> setLastViewedFor st cId >>= continue
      Nothing -> continue st
    _ -> continue st

lookupKeybinding :: Vty.Event -> [Keybinding] -> Maybe Keybinding
lookupKeybinding e kbs = listToMaybe $ filter ((== e) . kbEvent) kbs

channelSelectKeybindings :: [Keybinding]
channelSelectKeybindings =
    [ KB "Select matching channel"
         (Vty.EvKey Vty.KEnter []) $
         \st -> do
             -- If the text entered matches only one channel, switch to
             -- it
             let matches = filter (s `T.isInfixOf`) $
                                  (st^.csNames.cnChans <> st^.csNames.cnUsers)
                 s = st^.csChannelSelect
             continue =<< case matches of
                 [single] -> changeChannel single $ st & csMode .~ Main
                 _        -> return st

    , KB "Cancel channel selection"
         (Vty.EvKey Vty.KEsc []) $
         \st -> continue $ st & csMode .~ Main
    ]

helpKeybindings :: [Keybinding]
helpKeybindings =
    [ KB "Scroll up"
         (Vty.EvKey Vty.KUp []) $
         \st -> do
             vScrollBy (viewportScroll HelpViewport) (-1)
             continue st
    , KB "Scroll down"
         (Vty.EvKey Vty.KDown []) $
         \st -> do
             vScrollBy (viewportScroll HelpViewport) 1
             continue st
    , KB "Page up"
         (Vty.EvKey Vty.KPageUp []) $
         \st -> do
             vScrollBy (viewportScroll HelpViewport) (-1 * pageAmount)
             continue st
    , KB "Page down"
         (Vty.EvKey Vty.KPageDown []) $
         \st -> do
             vScrollBy (viewportScroll HelpViewport) pageAmount
             continue st
    , KB "Page down"
         (Vty.EvKey (Vty.KChar ' ') []) $
         \st -> do
             vScrollBy (viewportScroll HelpViewport) pageAmount
             continue st
    , KB "Return to the main interface"
         (Vty.EvKey Vty.KEsc []) $
         \st -> continue $ st & csMode .~ Main
    ]

mainKeybindings :: [Keybinding]
mainKeybindings =
    [ KB "Show this help screen"
         (Vty.EvKey (Vty.KFun 1) []) $
         showHelpScreen >=> continue

    , KB "Enter fast channel selection mode"
         (Vty.EvKey (Vty.KChar 'g') [Vty.MCtrl]) $
         beginChannelSelect >=> continue

    , KB "Quit"
         (Vty.EvKey (Vty.KChar 'q') [Vty.MCtrl]) halt

    , KB "Tab-complete forward"
         (Vty.EvKey (Vty.KChar '\t') []) $
         tabComplete Forwards

    , KB "Tab-complete backward"
         (Vty.EvKey (Vty.KBackTab) []) $
         tabComplete Backwards

    , KB "Scroll up in the channel input history"
         (Vty.EvKey Vty.KUp []) $
         continue . channelHistoryBackward

    , KB "Scroll down in the channel input history"
         (Vty.EvKey Vty.KDown []) $
         continue . channelHistoryForward

    , KB "Page up in the channel message list"
         (Vty.EvKey Vty.KPageUp []) $
         channelPageUp >=> continue

    , KB "Page down in the channel message list"
         (Vty.EvKey Vty.KPageDown []) $
         channelPageDown >=> continue

    , KB "Change to the next channel in the channel list"
         (Vty.EvKey (Vty.KChar 'n') [Vty.MCtrl]) $
         nextChannel >=> continue

    , KB "Change to the previous channel in the channel list"
         (Vty.EvKey (Vty.KChar 'p') [Vty.MCtrl]) $
         prevChannel >=> continue

    , KB "Change to the next channel with unread messages"
         (Vty.EvKey (Vty.KChar 'a') [Vty.MMeta]) $
         nextUnreadChannel >=> continue

    , KB "Change to the most recently-focused channel"
         (Vty.EvKey (Vty.KChar 's') [Vty.MMeta]) $
         recentChannel >=> continue

    , KB "Send the current message"
         (Vty.EvKey Vty.KEnter []) $ \st -> do
           handleInputSubmission $ st & csCurrentCompletion .~ Nothing
    ]

handleInputSubmission :: ChatState -> EventM Name (Next ChatState)
handleInputSubmission st = do
  let (line:_) = getEditContents (st^.cmdLine)
      cId = currentChannelId st
      st' = st & cmdLine %~ applyEdit clearZipper
               & csInputHistory %~ addHistoryEntry line cId
               & csInputHistoryPosition.at cId .~ Nothing
  case T.uncons line of
    Just ('/',cmd) -> dispatchCommand cmd st'
    _              -> do
      liftIO (sendMessage st' line)
      continue st'

shouldSkipMessage :: T.Text -> Bool
shouldSkipMessage "" = True
shouldSkipMessage s = T.all (`elem` (" \t"::String)) s

sendMessage :: ChatState -> T.Text -> IO ()
sendMessage st msg =
    case shouldSkipMessage msg of
        True -> return ()
        False -> do
            let myId   = st^.csMe.userIdL
                chanId = currentChannelId st
                theTeamId = st^.csMyTeam.teamIdL
            doAsync st $ do
              pendingPost <- mkPendingPost msg myId chanId
              doAsync st $ do
                _ <- mmPost (st^.csConn) (st^.csTok) theTeamId pendingPost
                return ()
