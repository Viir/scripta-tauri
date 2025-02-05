port module Main exposing (main)

{- This is a starter app which presents a text label, text field, and a button.
   What you enter in the text field is echoed in the label.  When you press the
   button, the text in the label is revers
   This version uses `mdgriffith/elm-ui` for the view functions.
-}

import Browser
import Browser.Dom
import Json.Encode
import Config
import Dict exposing (Dict)
import Document exposing (Document)
import Element exposing (..)
import File.Download
import Html.Attributes
import Html.Events
import Http
import Json.Decode
import Json.Encode
import Keyboard
import List.Extra
import Maybe.Extra
import Model exposing (AppMode(..), Flags, Model, Msg(..), PopupState(..), SelectionState(..))
import PDF exposing (PDFMsg(..))
import Process
import Render.Msg exposing (MarkupMsg(..))
import Scripta.API
import Scripta.Language exposing (Language(..))
import String exposing (toInt)
import Task
import Text
import Time
import View.Editor
import View.Main
import View.Utility


main =
    Browser.element
        { init = init
        , view = View.Main.view
        , update = update
        , subscriptions = subscriptions
        }


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Time.every 500 ExportTick
        , Time.every 3000 DocumentSaveTick
        , receiveDocument (Json.Decode.decodeValue documentDecoder >> DocumentReceived)
        , receivePreferences (Json.Decode.decodeValue preferencesDecoder >> PreferencesReceived)
        , Sub.map KeyMsg Keyboard.subscriptions
        ]


autosave model =
    if model.documentNeedsSaving && model.document.path /= "NONE" then
        ( { model | documentNeedsSaving = False }, writeDocument (Document.encode model.document) )

    else
        ( model, Cmd.none )



-- OUTBOUND PORTS (toJS)


port readPreferences : Json.Encode.Value -> Cmd a


port setScriptaDirectory : Json.Encode.Value -> Cmd a


port writePreferences : Json.Encode.Value -> Cmd a


port writeDocument : Json.Encode.Value -> Cmd a


port openFile : Json.Encode.Value -> Cmd a



-- INBOUND PORTS (fromJS)


port receiveDocument : (Json.Encode.Value -> msg) -> Sub msg


port receivePreferences : (Json.Encode.Value -> msg) -> Sub msg


documentDecoder : Json.Decode.Decoder Document
documentDecoder =
    Json.Decode.map3 Document
        (Json.Decode.field "content" Json.Decode.string)
        (Json.Decode.field "name" Json.Decode.string)
        (Json.Decode.field "path" Json.Decode.string)


preferencesDecoder : Json.Decode.Decoder String
preferencesDecoder =
    Json.Decode.field "preferences" Json.Decode.string


initialDoc =
    { content = "\\title{Welcome!}\n\nPress  \\{strong{About} to continue\n", path = "NONE", name = "start.tex" }


init : Flags -> ( Model, Cmd Msg )
init flags =
    ( { count = 0
      , document = { content = Text.about, name = "about.tex", path = "NONE" }
      , initialText = "??????"
      , linenumber = 0
      , doSync = False
      , foundIdIndex = 0
      , searchSourceText = ""
      , searchCount = 0
      , selectedId = ""
      , selectionHighLighted = Unselected
      , foundIds = []
      , pressedKeys = []
      , documentNeedsSaving = False
      , editRecord = Scripta.API.init Dict.empty MicroLaTeXLang Text.about
      , language = MicroLaTeXLang
      , currentTime = Time.millisToPosix 0
      , printingState = PDF.PrintWaiting
      , tarFileState = PDF.TarFileWaiting
      , message = "Starting up"
      , ticks = 0
      , popupState = NoPopups
      , newFilename = ""
      , inputFilename = ""
      , preferences = Dict.empty
      , homeDirectory = Nothing
      , mode = EditorMode
      }
    , Cmd.batch
        [ View.Utility.jumpToTop Config.renderedTextViewportID
        , View.Utility.jumpToTop "input-text"
        , readPreferences Json.Encode.null
        , delayCmd 1 (SetExampleDocument "about.tex")
        , setScriptaDirectory Json.Encode.null
        ]
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NoOp ->
            ( model, Cmd.none )

        DocumentSaveTick _ ->
            autosave model

        ExportTick newTime ->
            let
                printingState =
                    if model.printingState == PDF.PrintProcessing && model.ticks > 2 then
                        PDF.PrintReady

                    else if model.printingState == PDF.PrintReady && model.ticks > 10 then
                        PDF.PrintWaiting

                    else
                        model.printingState

                tarFileState =
                    if model.tarFileState == PDF.TarFileProcessing && model.ticks > 2 then
                        PDF.TarFileReady

                    else if model.tarFileState == PDF.TarFileReady && model.ticks > 10 then
                        PDF.TarFileWaiting

                    else
                        model.tarFileState

                ticks =
                    if model.ticks > 10 then
                        0

                    else
                        model.ticks + 1
            in
            ( { model
                | currentTime = newTime
                , ticks = ticks
                , tarFileState = tarFileState
                , printingState = printingState
              }
            , Cmd.none
            )

        InputText { position, source } ->
            ( { model
                | editRecord = Scripta.API.update model.editRecord source
                , document = Document.updateContent source model.document
                , count = model.count + 1
                , documentNeedsSaving = True
              }
            , Cmd.none
            )

        InputCursor { position, source } ->
            View.Editor.inputCursor { position = position, source = source } model

        SelectedText str ->
            syncLR { model | searchSourceText = str }

        -- InputText { position, source } ->
        --             Frontend.Editor.inputText model { position = position, source = source }
        SetExampleDocument documentName ->
            let
                doc =
                    case documentName of
                        "demo.L0" ->
                            { content = Text.l0Demo, name = documentName, path = "NONE" }

                        "demo.tex" ->
                            { content = Text.microLaTeXDemo, name = documentName, path = "NONE" }

                        "demo.md" ->
                            { content = Text.xMarkdown, name = documentName, path = "NONE" }

                        "about.tex" ->
                            { content = Text.about, name = documentName, path = "NONE" }

                        _ ->
                            { content = Text.nada, name = "nada.L0", path = "NONE" }
            in
            model |> loadDocument doc |> (\m -> ( m, Cmd.batch [ View.Utility.jumpToTop Config.renderedTextViewportID, View.Utility.jumpToTop "input-text" ] ))

        GetTarFile ->
            let
                defaultSettings =
                    Scripta.API.defaultSettings
            in
            ( { model
                | ticks = 0
                , tarFileState = PDF.TarFileProcessing
                , message = "requesting TAR file"
              }
            , PDF.tarCmd model.currentTime { defaultSettings | isStandaloneDocument = True } model.editRecord.tree
                |> Cmd.map PDF
            )

        --
        PDF _ ->
            ( model, Cmd.none )

        Model.GotPdfLink result ->
            ( { model | printingState = PDF.PrintReady, message = "Got PDF Link" }, Cmd.none )

        Model.ChangePrintingState printingState ->
            ( { model | printingState = printingState, message = "Changing printing state" }, Cmd.none )

        PrintToPDF ->
            let
                defaultSettings =
                    Scripta.API.defaultSettings

                exportSettings =
                    { defaultSettings | isStandaloneDocument = True }
            in
            ( { model | ticks = 0, printingState = PDF.PrintProcessing, message = "requesting PDF" }, PDF.printCmd model.currentTime exportSettings model.editRecord.tree |> Cmd.map PDF )

        Model.GotTarFile result ->
            ( { model | printingState = PDF.PrintReady, message = "Got TarFile" }, Cmd.none )

        Model.ChangeTarFileState tarFileState ->
            ( { model | tarFileState = tarFileState, message = "Changing tar file state" }, Cmd.none )

        Render _ ->
            ( model, Cmd.none )

        Export ->
            ( model, Cmd.none )

        RawExport ->
            let
                doc =
                    { name = fileName, path = path, content = content }

                defaultSettings =
                    Scripta.API.defaultSettings

                exportSettings =
                    { defaultSettings | isStandaloneDocument = True }

                content =
                    Scripta.API.rawExport exportSettings model.editRecord.tree

                rawFileName =
                    model.document.name
                        |> String.split "."
                        |> List.reverse
                        |> List.drop 1
                        |> List.reverse
                        |> String.join "."

                fileName =
                    rawFileName ++ "-raw.tex"

                path =
                    "scripta/" ++ fileName
            in
            ( { model | message = "Saved " ++ fileName }, writeDocument (Document.encode doc) )

        -- PORTS
        SendDocument ->
            let
                message =
                    if model.document.path == "NONE" then
                        "Document is read-only"

                    else
                        "Saved as Desktop/" ++ model.document.path
            in
            if model.document.path == "NONE" then
                ( { model | message = message, documentNeedsSaving = False }, Cmd.none )

            else
                ( { model | message = message, documentNeedsSaving = False }, writeDocument (Document.encode model.document) )

        OpenFile dir ->
            ( model, openFile Json.Encode.null )

        NewFile ->
            ( { model | popupState = NewDocumentWindowOpen, inputFilename = "", newFilename = "" }, Cmd.none )

        SetLanguage lang ->
            ( { model | language = lang }, Cmd.none )

        InputNewFileName str ->
            ( { model | inputFilename = str }, Cmd.none )

        ClosePopup ->
            ( { model | popupState = NoPopups }, Cmd.none )

        CreateFile ->
            let
                newFilename =
                    case model.language of
                        L0Lang ->
                            model.inputFilename ++ ".L0"

                        MicroLaTeXLang ->
                            model.inputFilename ++ ".tex"

                        XMarkdownLang ->
                            model.inputFilename ++ ".md"

                        _ ->
                            ".tex"

                languageName =
                    case model.language of
                        L0Lang ->
                            "L0"

                        MicroLaTeXLang ->
                            "MicroLaTeX"

                        XMarkdownLang ->
                            "XMarkdown"

                        _ ->
                            "MicroLaTeX"

                newPreferences =
                    Dict.insert "language" languageName model.preferences

                preferenceString =
                    Dict.toList newPreferences |> List.map (\( a, b ) -> a ++ ": " ++ b) |> String.join "\n"
            in
            { model | popupState = NoPopups, preferences = newPreferences }
                |> loadDocument { name = newFilename, content = "new document\n", path = "scripta/" ++ newFilename }
                |> (\m -> ( { m | newFilename = newFilename, documentNeedsSaving = True }, writePreferences (encodeStringWithTag "preferences" preferenceString) ))

        DocumentReceived result ->
            case result of
                Err _ ->
                    ( { model | message = "Error opening document" }, Cmd.none )

                Ok doc ->
                    case List.Extra.unconsLast (doc.name |> String.split "/") of
                        Nothing ->
                            ( { model | message = "Error opening document" }, Cmd.none )

                        Just ( name_, _ ) ->
                            { model | message = "Document opened" }
                                |> loadDocument { doc | name = name_, path = fixPath doc.path }
                                |> (\m -> ( m, Cmd.none ))

        Reload document ->
            ( model |> loadDocument document, Cmd.none )

        PreferencesReceived result ->
            case result of
                Err _ ->
                    ( { model | preferences = Dict.empty, message = "Error getting preferences" }, Cmd.none )

                Ok prefs ->
                    let
                        preferences =
                            extractPrefs prefs

                        language =
                            case getLanguage preferences of
                                Just lang ->
                                    lang

                                Nothing ->
                                    model.language
                    in
                    ( { model | message = "Preferences: " ++ String.replace "\n" ", " prefs, preferences = preferences, language = language }, Cmd.none )

        Refresh ->
            ( { model | editRecord = Scripta.API.init Dict.empty (Document.language model.document) model.document.content }, Cmd.none )

        SyncLR ->
            syncLR model

        SetViewPortForElement data ->
            setViewportForElement model data

        KeyMsg keyMsg ->
            updateKeys model keyMsg

        RenderMarkupMsg msg_ ->
            sync model msg_

        SetAppMode newMode ->
            let
                currentDocument =
                    model.document
            in
            -- ({ model | mode = newMode, document = Document.default}, delayCmd 10 (Reload  currentDocument))
            ( { model | mode = newMode }, Cmd.none )


setViewportForElement : Model -> Result xx ( Browser.Dom.Element, Browser.Dom.Viewport ) -> ( Model, Cmd Msg )
setViewportForElement model result =
    case result of
        Ok ( element, viewport ) ->
            ( model
            , View.Utility.setViewPortForSelectedLine element viewport
            )

        Err _ ->
            -- TODO: restore error message
            -- ( { model | message = model.message ++ ", could not set viewport" }, Cmd.none )
            ( model, Cmd.none )


{-| EDITOR SYNCHRONIZATION
-}
sync : Model -> MarkupMsg -> ( Model, Cmd Msg )
sync model msg_ =
    case msg_ of
        SendMeta meta ->
            -- ( { model | lineNumber = m.loc.begin.row, message = "line " ++ String.fromInt (m.loc.begin.row + 1) }, Cmd.none )
            ( { model | linenumber = meta.begin }, Cmd.none )

        SendLineNumber line ->
            -- This is the code that highlights a line in the source text when rendered text is clicked.
            let
                linenumber =
                    line |> String.toInt |> Maybe.withDefault 0 |> (\x -> x - 1)
            in
            ( { model | linenumber = linenumber, message = "Line " ++ (linenumber |> String.fromInt) }, Cmd.none )

        SelectId id ->
            -- the element with this id will be highlighted
            if model.selectionHighLighted == IdSelected id then
                ( { model | selectedId = "_??_", selectionHighLighted = Unselected }, View.Utility.setViewportForElement Config.renderedTextViewportID id )

            else
                ( { model | selectedId = id, selectionHighLighted = IdSelected id }, View.Utility.setViewportForElement Config.renderedTextViewportID id )

        HighlightId id ->
            -- the element with this id will be highlighted
            if model.selectionHighLighted == IdSelected id then
                ( { model | selectedId = "_??_", selectionHighLighted = Unselected }, Cmd.none )

            else
                ( { model | selectedId = id, selectionHighLighted = IdSelected id }, Cmd.none )

        GetPublicDocument _ _ ->
            ( model, Cmd.none )

        GetPublicDocumentFromAuthor _ _ _ ->
            ( model, Cmd.none )

        GetDocumentWithSlug _ _ ->
            ( model, Cmd.none )

        ProposeSolution _ ->
            ( model, Cmd.none )


extractPrefs : String -> Dict String String
extractPrefs data =
    data
        |> String.lines
        |> List.map (String.split ":")
        |> List.map (List.map String.trim)
        |> List.filter (\line -> List.length line == 2)
        |> List.map listToTuple
        |> Maybe.Extra.values
        |> Dict.fromList


listToTuple : List a -> Maybe ( a, a )
listToTuple list =
    case list of
        first :: second :: [] ->
            Just ( first, second )

        _ ->
            Nothing


fixPath : String -> String
fixPath str =
    str
        |> String.split "/"
        |> List.Extra.dropWhile (\s -> s /= "Desktop")
        |> List.drop 1
        |> String.join "/"


download : String -> String -> Cmd msg
download fileName fileContents =
    File.Download.string fileName "application/x-tex" fileContents



-- HELPERS


adjustId : String -> String
adjustId str =
    case String.toInt str of
        Nothing ->
            str

        Just n ->
            String.fromInt (n + 2)


loadDocument : Document -> Model -> Model
loadDocument doc model =
    { model
        | document = Document.updateContent doc.content doc
        , documentNeedsSaving = False
        , initialText = doc.content
        , editRecord = Scripta.API.init Dict.empty (Document.language doc) doc.content
        , language = Document.language doc
        , count = model.count + 1
    }



-- VIEWPORT


htmlId : String -> Attribute msg
htmlId str =
    htmlAttribute (Html.Attributes.id str)



-- HELPERS

encodeStringWithTag: String -> String -> Json.Encode.Value
encodeStringWithTag tag str = 
   Json.Encode.object [ (tag, Json.Encode.string str)]

getLanguage : Dict String String -> Maybe Language
getLanguage dict =
    case Dict.get "language" dict of
        Just "L0" ->
            Just L0Lang

        Just "MicroLaTeX" ->
            Just MicroLaTeXLang

        Just "XMarkdown" ->
            Just XMarkdownLang

        _ ->
            Nothing


updateKeys model keyMsg =
    let
        pressedKeys =
            Keyboard.update keyMsg model.pressedKeys

        doSync =
            if List.member Keyboard.Control pressedKeys && List.member (Keyboard.Character "S") pressedKeys then
                not model.doSync

            else
                model.doSync
    in
    ( { model | pressedKeys = pressedKeys, doSync = doSync }
    , Cmd.none
    )


delayCmd : Float -> msg -> Cmd msg
delayCmd delay msg =
    Task.perform (\_ -> msg) (Process.sleep delay)


syncLR : Model -> ( Model, Cmd Msg )
syncLR model =
    let
        data =
            if model.foundIdIndex == 0 then
                let
                    foundIds_ =
                        Scripta.API.matchingIdsInAST model.searchSourceText model.editRecord.tree

                    id_ =
                        List.head foundIds_ |> Maybe.withDefault "(nothing)"
                in
                { foundIds = foundIds_
                , foundIdIndex = 1
                , cmd = View.Utility.setViewportForElement Config.renderedTextViewportID id_
                , selectedId = id_
                , searchCount = 0
                }

            else
                let
                    id_ =
                        List.Extra.getAt model.foundIdIndex model.foundIds |> Maybe.withDefault "(nothing)"
                in
                { foundIds = model.foundIds
                , foundIdIndex = modBy (List.length model.foundIds) (model.foundIdIndex + 1)
                , cmd = View.Utility.setViewportForElement Config.renderedTextViewportID id_
                , selectedId = id_
                , searchCount = model.searchCount + 1
                }
    in
    ( { model
        | selectedId = data.selectedId
        , foundIds = data.foundIds
        , foundIdIndex = data.foundIdIndex
        , searchCount = data.searchCount
        , message = adjustId data.selectedId
      }
    , data.cmd
    )


firstSyncLR : Model -> String -> ( Model, Cmd Msg )
firstSyncLR model searchSourceText =
    ( { model | message = "SYNC: " ++ searchSourceText }, Cmd.none )


