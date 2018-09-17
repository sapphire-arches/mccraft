port module Main exposing (Model, init, main)

import Browser
import Debug
import Graph exposing (Edge, Graph, Node, NodeId)
import Html exposing (..)
import Html.Attributes exposing (class, id, placeholder, src, type_)
import Html.Events exposing (..)
import Html.Keyed
import Http
import IntDict
import Json.Decode as Decode exposing (Decoder)
import Json.Decode.Pipeline as Pipeline exposing (required)
import Json.Encode as Encode
import Random
import Url.Builder as Url



-- import Visualization.Force as Force exposing (State)
-- import Visualization.Scale as Scale exposing (SequentialScale)


main =
    Browser.element
        { init = init
        , update = update
        , subscriptions = subscriptions
        , view = view
        }



-- Communication structures


type ItemType
    = ItemStack
    | Fluid
    | UnknownType


matchItemType : String -> ItemType
matchItemType x =
    case x of
        "Item" ->
            ItemStack

        "Fluid" ->
            Fluid

        _ ->
            UnknownType


itemType : Decoder ItemType
itemType =
    Decode.map matchItemType Decode.string


type alias ItemSpec =
    { id : Int
    , itemName : String
    , minecraftId : String
    , ty : ItemType
    , quantity : Int
    }


itemSpecDecoder : Decoder ItemSpec
itemSpecDecoder =
    Decode.succeed ItemSpec
        |> required "item_id" Decode.int
        |> required "human_name" Decode.string
        |> required "minecraft_id" Decode.string
        |> required "ty" itemType
        |> required "quantity" Decode.int


type alias Item =
    { id : Int
    , itemName : String
    , minecraftId : String
    , ty : ItemType
    }


type alias RenderableItem a =
    { a
        | minecraftId : String
        , ty : ItemType
    }


itemDecoder : Decoder Item
itemDecoder =
    Decode.succeed Item
        |> required "id" Decode.int
        |> required "human_name" Decode.string
        |> required "minecraft_id" Decode.string
        |> required "ty" itemType



-- Ports


graphEdgeEncoder : Graph.Edge GraphEdge -> Encode.Value
graphEdgeEncoder edge =
    Encode.object
        [ ( "source", Encode.int edge.from )
        , ( "target", Encode.int edge.to )
        , ( "id", Encode.int edge.label.id )
        ]


graphNodeEncoder : Graph.Node Entity -> Encode.Value
graphNodeEncoder ent =
    Encode.object
        [ ( "id", Encode.int ent.id )
        , ( "name", Encode.string ent.label.name )
        ]


graphEncoder : Graph Entity GraphEdge -> Encode.Value
graphEncoder graph =
    Encode.object
        [ ( "edges", Encode.list graphEdgeEncoder (Graph.edges graph) )
        , ( "nodes", Encode.list graphNodeEncoder (Graph.nodes graph) )
        ]


port edgeOut : Encode.Value -> Cmd msg


port nodeOut : Encode.Value -> Cmd msg



-- Model


type alias Entity =
    { rank : Int, name : String }


mkGraphNode : NodeId -> Int -> String -> Graph.Node Entity
mkGraphNode id rank name =
    Graph.Node id (Entity rank name)


type alias GraphEdge =
    { id : Int }


type alias Model =
    { graph : Graph Entity GraphEdge
    , searchResults : List Item
    , errorMessage : Maybe String
    }


init : () -> ( Model, Cmd Msg )
init _ =
    ( Model Graph.empty [] Nothing, Cmd.none )



-- Update


type RandLinkMsg
    = CreateLink
    | ResultLink ( Int, Int )


createLinkGenerator : Int -> Random.Generator ( Int, Int )
createLinkGenerator numNodes =
    Random.pair (Random.int 0 (numNodes - 1)) (Random.int 0 (numNodes - 2))


type RandNodeMsg
    = CreateNode
    | ResultNode Int


createNodeGenerator : Int -> Random.Generator Int
createNodeGenerator numNodes =
    Random.int numNodes (numNodes + 1)


type Msg
    = NewRandomLink RandLinkMsg
    | NewRandomNode RandNodeMsg
    | SearchItem String
    | ItemSearchResults (Result Http.Error (List Item))
    | AddItem Item


updateLinkMsg : RandLinkMsg -> Graph Entity GraphEdge -> ( Graph Entity GraphEdge, Cmd Msg )
updateLinkMsg msg model =
    case msg of
        CreateLink ->
            ( model, Random.generate (\x -> NewRandomLink (ResultLink x)) (createLinkGenerator (Graph.size model)) )

        ResultLink ( source, dest ) ->
            let
                target =
                    if dest >= source then
                        modBy (dest + 1) (Graph.size model)

                    else
                        dest

                edgeLabel =
                    { id = List.length (Graph.edges model)
                    }

                newGraph =
                    Graph.update source
                        (\x ->
                            case x of
                                Just ({ node, incoming, outgoing } as ctx) ->
                                    Just { ctx | outgoing = IntDict.insert target edgeLabel outgoing }

                                Nothing ->
                                    Nothing
                        )
                        model

                newEdge =
                    Graph.Edge source target edgeLabel
            in
            ( newGraph, edgeOut (graphEdgeEncoder newEdge) )


updateNodeMsg : RandNodeMsg -> Graph Entity GraphEdge -> ( Graph Entity GraphEdge, Cmd Msg )
updateNodeMsg msg model =
    case msg of
        CreateNode ->
            ( model, Random.generate (\x -> NewRandomNode (ResultNode x)) (createNodeGenerator (Graph.size model)) )

        ResultNode n ->
            let
                newNode =
                    mkGraphNode (Graph.size model) 0 (Debug.toString n)

                newGraph =
                    Graph.insert
                        { node = newNode
                        , incoming = IntDict.empty
                        , outgoing = IntDict.empty
                        }
                        model
            in
            ( newGraph, nodeOut (graphNodeEncoder newNode) )


doItemSearch : String -> Model -> ( Model, Cmd Msg )
doItemSearch term model =
    if String.length term < 3 then
        ( { model | searchResults = [] }, Cmd.none )

    else
        let
            url =
                Url.relative [ "search.json" ] [ Url.string "q" term ]
        in
        ( model, Http.send ItemSearchResults (Http.get url (Decode.list itemDecoder)) )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    Debug.log ("Processing message " ++ Debug.toString msg)
        (case msg of
            NewRandomLink linkMsg ->
                let
                    ( newGraph, linkResp ) =
                        updateLinkMsg linkMsg model.graph
                in
                ( { model | graph = newGraph }, linkResp )

            NewRandomNode nodeMsg ->
                let
                    ( newGraph, nodeResp ) =
                        updateNodeMsg nodeMsg model.graph
                in
                ( { model | graph = newGraph }, nodeResp )

            SearchItem term ->
                doItemSearch term model

            ItemSearchResults res ->
                case res of
                    Ok item ->
                        ( { model | searchResults = item }, Cmd.none )

                    Err item ->
                        --- TODO: display an error to the user. Build infrastructure like Flask's flashes?
                        case item of
                            Http.BadPayload errMsg _ ->
                                ( { model | errorMessage = Just errMsg }, Cmd.none )

                            Http.BadUrl errMsg ->
                                ( { model | errorMessage = Just errMsg }, Cmd.none )

                            Http.Timeout ->
                                ( { model | errorMessage = Just "Network timeout while searching for items" }, Cmd.none )

                            Http.NetworkError ->
                                ( { model | errorMessage = Just "Network error while searching for items" }, Cmd.none )

                            Http.BadStatus resp ->
                                ( { model | errorMessage = Just "Bad status code" }, Cmd.none )

            AddItem item ->
                Debug.log (Debug.toString item) ( { model | searchResults = [] }, Cmd.none )
        )



-- VIEW


debugPane : Model -> Html Msg
debugPane model =
    let
        baseContent =
            [ button [ onClick (NewRandomLink CreateLink) ] [ text "New random link" ]
            , button [ onClick (NewRandomNode CreateNode) ] [ text "New random node" ]
            , text (Graph.toString (\v -> Just v.name) (\e -> Just (Debug.toString e.id)) model.graph)
            ]

        errorContent =
            case model.errorMessage of
                Nothing ->
                    []

                Just msg ->
                    [ br [] [], code [] [ text msg ] ]
    in
    div [ class "debug-pane" ] (baseContent ++ errorContent)


urlForItem : RenderableItem a -> String
urlForItem ri =
    let
        formatMCID s =
            String.append (String.replace ":" "_" s) ".png"
    in
    case ri.ty of
        Fluid ->
            Url.relative [ "images", "fluids", formatMCID ri.minecraftId ] []

        ItemStack ->
            Url.relative [ "images", "items", formatMCID ri.minecraftId ] []

        UnknownType ->
            Url.relative [ "static", "ohno.png" ] []


searchResult : Int -> Item -> Html Msg
searchResult index item =
    div
        [ class "search-result"
        , class
            (if modBy 2 index == 0 then
                "even"

             else
                "odd"
            )
        , onClick (AddItem item)
        ]
        [ div [ class "search-result-left" ]
            [ img
                [ class "search-result-icon mc-texture"
                , src (urlForItem item)
                ]
                [ text "Item preview" ]
            , div
                [ class "search-result-name" ]
                [ text item.itemName ]
            ]
        , div
            [ class "search-mcid" ]
            [ text item.minecraftId ]
        ]


searchBox : Model -> Html Msg
searchBox model =
    div [ class "primary-search-wrapper" ]
        [ input
            [ id "primary-search"
            , class "primary-search"
            , type_ "text"
            , placeholder "Item"
            , onInput SearchItem
            ]
            []
        , div [ class "search-results" ] (List.indexedMap searchResult model.searchResults)
        ]


view : Model -> Html Msg
view model =
    div []
        [ debugPane model
        , searchBox model
        ]



-- Subscriptions


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.none
