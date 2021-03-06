module Servant.Elm.Generate where

import           Data.Char           (toLower)
import           Data.List           (intercalate, nub)
import           Data.Maybe          (catMaybes)
import           Data.Proxy          (Proxy)
import qualified Data.Text           as T
import           Servant.Elm.Client  (HasElmClient, elmClient)
import           Servant.Elm.Request (Request (..))
import           Servant.Foreign     (ArgType (..), QueryArg (..), Segment (..),
                                      SegmentType (..), camelCase)


{-|
Options to configure how code is generated.
-}
data ElmOptions = ElmOptions
  { {- | The protocol, host and any path prefix to be used as the base for all
    requests.

    Example: @"https://mydomain.com/api/v1"@
    -}
    urlPrefix :: String }


{-|
The default options for generating Elm code.

[@urlPrefix@] (An empty string)
-}
defElmOptions :: ElmOptions
defElmOptions = ElmOptions
  { urlPrefix = "" }


{-|
Default imports required by generated Elm code.

You probably want to include this at the top of your generated Elm module.

The default required imports are:

> import Json.Decode exposing ((:=))
> import Json.Decode.Extra exposing ((|:))
> import Json.Encode
> import Http
> import String
> import Task
-}
defElmImports :: String
defElmImports =
  unlines
    [ "import Json.Decode exposing ((:=))"
    , "import Json.Decode.Extra exposing ((|:))"
    , "import Json.Encode"
    , "import Http"
    , "import String"
    , "import Task"
    ]


{-|
Generate Elm code for the API with default options.

Returns a list of Elm code definitions with everything you need to query your
Servant API from Elm: type definitions, JSON decoders, JSON encoders, and query
functions.

You could spit these out to a file and call them from your Elm code, but you
would be better off creating a 'Spec' with the result and using 'specsToDir',
which handles the module name for you.
-}
generateElmForAPI :: (HasElmClient layout)
                  => Proxy layout -> [String]
generateElmForAPI = generateElmForAPIWith defElmOptions


{-|
Generate Elm code for the API with custom options.
-}
generateElmForAPIWith :: (HasElmClient layout)
                      => ElmOptions -> Proxy layout -> [String]
generateElmForAPIWith opts = nub . concatMap (generateElmForRequest opts) . elmClient


-- TODO: headers, content type?, url encoders?
generateElmForRequest :: ElmOptions -> Request -> [String]
generateElmForRequest opts request = typeDefs request ++ decoderDefs request ++ encoderDefs request ++ [func]
  where func = funcName ++ " : " ++ (typeSignature . reverse . fnSignature) request ++ "\n"
                  ++ funcNameArgs ++ " =\n"
                  ++ "  let\n"
                  ++ letParams "    "
                  ++ "    request =\n"
                  ++ "      { verb =\n"
                  ++ "          \"" ++ httpMethod request ++ "\"\n"
                  ++ "      , headers =\n"
                  ++ "          [(\"Content-Type\", \"application/json\")]\n"
                  ++ "      , url =\n"
                  ++ "          " ++ url ++ "\n"
                  ++ urlParams "          "
                  ++ "      , body =\n"
                  ++ "          " ++ body ++ "\n"
                  ++ "      }\n"
                  ++ "  in\n"
                  ++ "    Http.fromJson\n"
                  ++ "      " ++ decoder request ++ "\n"
                  ++ "      (Http.send Http.defaultSettings request)"
        funcName = (T.unpack . camelCase . map T.pack . (:) (map toLower (httpMethod request)) . reverse) (fnName request)
        typeSignature [x] = "Task.Task Http.Error (" ++ x ++ ")"
        typeSignature (x:xs) = x ++ " -> " ++ typeSignature xs
        typeSignature [] = ""
        funcNameArgs = unwords (funcName : args)
        url = buildUrl (urlPrefix opts) segments
        args = reverse (argNames request)
        segments = (reverse . urlSegments) request
        params = (map paramToStr . reverse . urlQueryStr) request
        letParams indent =
          if null params then
            ""
          else
            indent
            ++ intercalate ("\n" ++ indent)
                 [ "params ="
                 , "  List.filter (not << String.isEmpty)"
                 , "    [ " ++ intercalate ("\n" ++ indent ++ "    , ") params
                 , "    ]"
                 ]
            ++ "\n"
        urlParams indent =
          if null params then
            ""
          else
            indent
            ++ intercalate ("\n" ++ indent)
                 [ "++ if List.isEmpty params then"
                 , "     \"\""
                 , "   else"
                 , "     \"?\" ++ String.join \"&\" params"
                 ]
            ++ "\n"
        body = case bodyEncoder request of
                 Just encoder -> "Http.string (Json.Encode.encode 0 (" ++ encoder ++ " body))"
                 Nothing -> "Http.empty"


buildUrl :: String -> [Segment] -> String
buildUrl prefix segments =
  (intercalate newLine . catMaybes)
    [ nullOr prefix $
        "\"" ++ prefix ++ "\""
    , nullOr segments $
        "\"/\" ++ "
        ++ intercalate (newLine ++ "\"/\" ++ ")
             (map segmentToStr segments)
    ]
  where newLine = "\n          ++ "
        nullOr t x = if null t
                        then Nothing
                        else Just x


segmentToStr :: Segment -> String
segmentToStr (Segment (Static s)) = "\"" ++ T.unpack s ++ "\""
segmentToStr (Segment (Cap (s, _)))    = "(" ++ T.unpack s ++ " |> toString |> Http.uriEncode)"


paramToStr :: QueryArg -> String
paramToStr qarg =
  case _argType qarg of
    Normal ->
      intercalate newLine
        [ name
        , "  |> Maybe.map (toString >> Http.uriEncode >> (++) \"" ++ name ++ "=\")"
        , "  |> Maybe.withDefault \"\""
        ]
    Flag ->
      intercalate newLine
        ["if " ++ name ++ " then"
        , "  \"" ++ name ++ "=\""
        , "else"
        , "  \"\""
        ]
    List ->
      intercalate newLine
        [ name
        , "  |> List.map (\\val -> \"" ++ name ++ "[]=\" ++ (val |> toString |> Http.uriEncode))"
        , "  |> String.join \"&\""
        ]
  where name = T.unpack (fst (_argName qarg))
        newLine = "\n          "
