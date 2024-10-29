module Builder.Deps.Solver exposing
    ( AppSolution(..)
    , Connection(..)
    , Details(..)
    , Env(..)
    , InnerSolver(..)
    , Solver
    , SolverResult(..)
    , State
    , addToApp
    , envDecoder
    , envEncoder
    , initEnv
    , verify
    )

import Builder.Deps.Registry as Registry
import Builder.Deps.Website as Website
import Builder.Elm.Outline as Outline
import Builder.File as File
import Builder.Http as Http
import Builder.Reporting.Exit as Exit
import Builder.Stuff as Stuff
import Compiler.Elm.Constraint as C
import Compiler.Elm.Package as Pkg
import Compiler.Elm.Version as V
import Compiler.Json.Decode as D
import Data.IO as IO exposing (IO)
import Data.Map as Dict exposing (Dict)
import Json.Decode as Decode
import Json.Encode as Encode
import Utils.Crash exposing (crash)
import Utils.Main as Utils



-- SOLVER


type Solver a
    = Solver (State -> IO (InnerSolver a))


type InnerSolver a
    = ISOk State a
    | ISBack State
    | ISErr Exit.Solver


type State
    = State Stuff.PackageCache Connection Registry.Registry (Dict ( Pkg.Name, V.Version ) Constraints)


type Constraints
    = Constraints C.Constraint (Dict Pkg.Name C.Constraint)


type Connection
    = Online Http.Manager
    | Offline



-- RESULT


type SolverResult a
    = SolverOk a
    | NoSolution
    | NoOfflineSolution
    | SolverErr Exit.Solver



-- VERIFY -- used by Elm.Details


type Details
    = Details V.Version (Dict Pkg.Name C.Constraint)


verify : Stuff.PackageCache -> Connection -> Registry.Registry -> Dict Pkg.Name C.Constraint -> IO (SolverResult (Dict Pkg.Name Details))
verify cache connection registry constraints =
    Stuff.withRegistryLock cache <|
        case try constraints of
            Solver solver ->
                solver (State cache connection registry Dict.empty)
                    |> IO.fmap
                        (\result ->
                            case result of
                                ISOk s a ->
                                    SolverOk (Dict.map (addDeps s) a)

                                ISBack _ ->
                                    noSolution connection

                                ISErr e ->
                                    SolverErr e
                        )


addDeps : State -> Pkg.Name -> V.Version -> Details
addDeps (State _ _ _ constraints) name vsn =
    case Dict.get ( name, vsn ) constraints of
        Just (Constraints _ deps) ->
            Details vsn deps

        Nothing ->
            crash "compiler bug manifesting in Deps.Solver.addDeps"


noSolution : Connection -> SolverResult a
noSolution connection =
    case connection of
        Online _ ->
            NoSolution

        Offline ->
            NoOfflineSolution



-- ADD TO APP - used in Install


type AppSolution
    = AppSolution (Dict Pkg.Name V.Version) (Dict Pkg.Name V.Version) Outline.AppOutline


addToApp : Stuff.PackageCache -> Connection -> Registry.Registry -> Pkg.Name -> Outline.AppOutline -> IO (SolverResult AppSolution)
addToApp cache connection registry pkg ((Outline.AppOutline _ _ direct indirect testDirect testIndirect) as outline) =
    Stuff.withRegistryLock cache <|
        let
            allIndirects : Dict Pkg.Name V.Version
            allIndirects =
                Dict.union Pkg.compareName indirect testIndirect

            allDirects : Dict Pkg.Name V.Version
            allDirects =
                Dict.union Pkg.compareName direct testDirect

            allDeps : Dict Pkg.Name V.Version
            allDeps =
                Dict.union Pkg.compareName allDirects allIndirects

            attempt : (a -> C.Constraint) -> Dict Pkg.Name a -> Solver (Dict Pkg.Name V.Version)
            attempt toConstraint deps =
                try (Dict.insert Pkg.compareName pkg C.anything (Dict.map (\_ -> toConstraint) deps))
        in
        case
            oneOf
                (attempt C.exactly allDeps)
                [ attempt C.exactly allDirects
                , attempt C.untilNextMinor allDirects
                , attempt C.untilNextMajor allDirects
                , attempt (\_ -> C.anything) allDirects
                ]
        of
            Solver solver ->
                solver (State cache connection registry Dict.empty)
                    |> IO.fmap
                        (\result ->
                            case result of
                                ISOk s a ->
                                    SolverOk (toApp s pkg outline allDeps a)

                                ISBack _ ->
                                    noSolution connection

                                ISErr e ->
                                    SolverErr e
                        )


toApp : State -> Pkg.Name -> Outline.AppOutline -> Dict Pkg.Name V.Version -> Dict Pkg.Name V.Version -> AppSolution
toApp (State _ _ _ constraints) pkg (Outline.AppOutline elm srcDirs direct _ testDirect _) old new =
    let
        d : Dict Pkg.Name V.Version
        d =
            Dict.intersection new (Dict.insert Pkg.compareName pkg V.one direct)

        i : Dict Pkg.Name V.Version
        i =
            Dict.diff (getTransitive constraints new (Dict.toList d) Dict.empty) d

        td : Dict Pkg.Name V.Version
        td =
            Dict.intersection new (Dict.remove pkg testDirect)

        ti : Dict Pkg.Name V.Version
        ti =
            Dict.diff new (Utils.mapUnions Pkg.compareName [ d, i, td ])
    in
    AppSolution old new (Outline.AppOutline elm srcDirs d i td ti)


getTransitive : Dict ( Pkg.Name, V.Version ) Constraints -> Dict Pkg.Name V.Version -> List ( Pkg.Name, V.Version ) -> Dict Pkg.Name V.Version -> Dict Pkg.Name V.Version
getTransitive constraints solution unvisited visited =
    case unvisited of
        [] ->
            visited

        (( pkg, vsn ) as info) :: infos ->
            if Dict.member pkg visited then
                getTransitive constraints solution infos visited

            else
                let
                    (Constraints _ newDeps) =
                        Utils.find info constraints

                    newUnvisited : List ( Pkg.Name, V.Version )
                    newUnvisited =
                        Dict.toList (Dict.intersection solution (Dict.diff newDeps visited))

                    newVisited : Dict Pkg.Name V.Version
                    newVisited =
                        Dict.insert Pkg.compareName pkg vsn visited
                in
                getTransitive constraints solution infos <|
                    getTransitive constraints solution newUnvisited newVisited



-- TRY


try : Dict Pkg.Name C.Constraint -> Solver (Dict Pkg.Name V.Version)
try constraints =
    exploreGoals (Goals constraints Dict.empty)



-- EXPLORE GOALS


type Goals
    = Goals (Dict Pkg.Name C.Constraint) (Dict Pkg.Name V.Version)


exploreGoals : Goals -> Solver (Dict Pkg.Name V.Version)
exploreGoals (Goals pending solved) =
    let
        compare : ( Pkg.Name, b ) -> String
        compare ( name, _ ) =
            Pkg.toString name
    in
    case Utils.mapMinViewWithKey Pkg.compareName compare pending of
        Nothing ->
            pure solved

        Just ( ( name, constraint ), otherPending ) ->
            let
                goals1 : Goals
                goals1 =
                    Goals otherPending solved

                addVsn : V.Version -> Solver Goals
                addVsn =
                    addVersion goals1 name
            in
            getRelevantVersions name constraint
                |> bind (\( v, vs ) -> oneOf (addVsn v) (List.map addVsn vs))
                |> bind (\goals2 -> exploreGoals goals2)


addVersion : Goals -> Pkg.Name -> V.Version -> Solver Goals
addVersion (Goals pending solved) name version =
    getConstraints name version
        |> bind
            (\(Constraints elm deps) ->
                if C.goodElm elm then
                    foldM (addConstraint solved) pending (Dict.toList deps)
                        |> fmap
                            (\newPending ->
                                Goals newPending (Dict.insert Pkg.compareName name version solved)
                            )

                else
                    backtrack
            )


addConstraint : Dict Pkg.Name V.Version -> Dict Pkg.Name C.Constraint -> ( Pkg.Name, C.Constraint ) -> Solver (Dict Pkg.Name C.Constraint)
addConstraint solved unsolved ( name, newConstraint ) =
    case Dict.get name solved of
        Just version ->
            if C.satisfies newConstraint version then
                pure unsolved

            else
                backtrack

        Nothing ->
            case Dict.get name unsolved of
                Nothing ->
                    pure (Dict.insert Pkg.compareName name newConstraint unsolved)

                Just oldConstraint ->
                    case C.intersect oldConstraint newConstraint of
                        Nothing ->
                            backtrack

                        Just mergedConstraint ->
                            if oldConstraint == mergedConstraint then
                                pure unsolved

                            else
                                pure (Dict.insert Pkg.compareName name mergedConstraint unsolved)



-- GET RELEVANT VERSIONS


getRelevantVersions : Pkg.Name -> C.Constraint -> Solver ( V.Version, List V.Version )
getRelevantVersions name constraint =
    Solver <|
        \((State _ _ registry _) as state) ->
            case Registry.getVersions name registry of
                Just (Registry.KnownVersions newest previous) ->
                    case List.filter (C.satisfies constraint) (newest :: previous) of
                        [] ->
                            IO.pure (ISBack state)

                        v :: vs ->
                            IO.pure (ISOk state ( v, vs ))

                Nothing ->
                    IO.pure (ISBack state)



-- GET CONSTRAINTS


getConstraints : Pkg.Name -> V.Version -> Solver Constraints
getConstraints pkg vsn =
    Solver <|
        \((State cache connection registry cDict) as state) ->
            let
                key : ( Pkg.Name, V.Version )
                key =
                    ( pkg, vsn )

                compare : ( Pkg.Name, V.Version ) -> ( Pkg.Name, V.Version ) -> Order
                compare ( pkg1, vsn1 ) ( pkg2, vsn2 ) =
                    case Pkg.compareName pkg1 pkg2 of
                        EQ ->
                            V.compare vsn1 vsn2

                        order ->
                            order
            in
            case Dict.get key cDict of
                Just cs ->
                    IO.pure (ISOk state cs)

                Nothing ->
                    let
                        toNewState : Constraints -> State
                        toNewState cs =
                            State cache connection registry (Dict.insert compare key cs cDict)

                        home : String
                        home =
                            Stuff.package cache pkg vsn

                        path : String
                        path =
                            home ++ "/elm.json"
                    in
                    File.exists path
                        |> IO.bind
                            (\outlineExists ->
                                if outlineExists then
                                    File.readUtf8 path
                                        |> IO.bind
                                            (\bytes ->
                                                case D.fromByteString constraintsDecoder bytes of
                                                    Ok cs ->
                                                        case connection of
                                                            Online _ ->
                                                                IO.pure (ISOk (toNewState cs) cs)

                                                            Offline ->
                                                                Utils.dirDoesDirectoryExist (Stuff.package cache pkg vsn ++ "/src")
                                                                    |> IO.fmap
                                                                        (\srcExists ->
                                                                            if srcExists then
                                                                                ISOk (toNewState cs) cs

                                                                            else
                                                                                ISBack state
                                                                        )

                                                    Err _ ->
                                                        File.remove path
                                                            |> IO.fmap (\_ -> ISErr (Exit.SolverBadCacheData pkg vsn))
                                            )

                                else
                                    case connection of
                                        Offline ->
                                            IO.pure (ISBack state)

                                        Online manager ->
                                            let
                                                url : String
                                                url =
                                                    Website.metadata pkg vsn "elm.json"
                                            in
                                            Http.get manager url [] identity (IO.pure << Ok)
                                                |> IO.bind
                                                    (\result ->
                                                        case result of
                                                            Err httpProblem ->
                                                                IO.pure (ISErr (Exit.SolverBadHttp pkg vsn httpProblem))

                                                            Ok body ->
                                                                case D.fromByteString constraintsDecoder body of
                                                                    Ok cs ->
                                                                        Utils.dirCreateDirectoryIfMissing True home
                                                                            |> IO.bind (\_ -> File.writeUtf8 path body)
                                                                            |> IO.fmap (\_ -> ISOk (toNewState cs) cs)

                                                                    Err _ ->
                                                                        IO.pure (ISErr (Exit.SolverBadHttpData pkg vsn url))
                                                    )
                            )


constraintsDecoder : D.Decoder () Constraints
constraintsDecoder =
    D.mapError (\_ -> ()) Outline.decoder
        |> D.bind
            (\outline ->
                case outline of
                    Outline.Pkg (Outline.PkgOutline _ _ _ _ _ deps _ elmConstraint) ->
                        D.pure (Constraints elmConstraint deps)

                    Outline.App _ ->
                        D.failure ()
            )



-- ENVIRONMENT


type Env
    = Env Stuff.PackageCache Http.Manager Connection Registry.Registry


initEnv : IO (Result Exit.RegistryProblem Env)
initEnv =
    Utils.newEmptyMVar
        |> IO.bind
            (\mvar ->
                Utils.forkIO (IO.bind (Utils.putMVar Http.managerEncoder mvar) Http.getManager)
                    |> IO.bind
                        (\_ ->
                            Stuff.getPackageCache
                                |> IO.bind
                                    (\cache ->
                                        Stuff.withRegistryLock cache
                                            (Registry.read cache
                                                |> IO.bind
                                                    (\maybeRegistry ->
                                                        Utils.readMVar Http.managerDecoder mvar
                                                            |> IO.bind
                                                                (\manager ->
                                                                    case maybeRegistry of
                                                                        Nothing ->
                                                                            Registry.fetch manager cache
                                                                                |> IO.fmap
                                                                                    (\eitherRegistry ->
                                                                                        case eitherRegistry of
                                                                                            Ok latestRegistry ->
                                                                                                Ok <| Env cache manager (Online manager) latestRegistry

                                                                                            Err problem ->
                                                                                                Err problem
                                                                                    )

                                                                        Just cachedRegistry ->
                                                                            Registry.update manager cache cachedRegistry
                                                                                |> IO.fmap
                                                                                    (\eitherRegistry ->
                                                                                        case eitherRegistry of
                                                                                            Ok latestRegistry ->
                                                                                                Ok <| Env cache manager (Online manager) latestRegistry

                                                                                            Err _ ->
                                                                                                Ok <| Env cache manager Offline cachedRegistry
                                                                                    )
                                                                )
                                                    )
                                            )
                                    )
                        )
            )



-- INSTANCES


fmap : (a -> b) -> Solver a -> Solver b
fmap func (Solver solver) =
    Solver <|
        \state ->
            solver state
                |> IO.fmap
                    (\result ->
                        case result of
                            ISOk stateA arg ->
                                ISOk stateA (func arg)

                            ISBack stateA ->
                                ISBack stateA

                            ISErr e ->
                                ISErr e
                    )


pure : a -> Solver a
pure a =
    Solver (\state -> IO.pure (ISOk state a))


bind : (a -> Solver b) -> Solver a -> Solver b
bind callback (Solver solverA) =
    Solver <|
        \state ->
            solverA state
                |> IO.bind
                    (\resA ->
                        case resA of
                            ISOk stateA a ->
                                case callback a of
                                    Solver solverB ->
                                        solverB stateA

                            ISBack stateA ->
                                IO.pure (ISBack stateA)

                            ISErr e ->
                                IO.pure (ISErr e)
                    )


oneOf : Solver a -> List (Solver a) -> Solver a
oneOf ((Solver solverHead) as solver) solvers =
    case solvers of
        [] ->
            solver

        s :: ss ->
            Solver <|
                \state0 ->
                    solverHead state0
                        |> IO.bind
                            (\result ->
                                case result of
                                    ISOk stateA arg ->
                                        IO.pure (ISOk stateA arg)

                                    ISBack stateA ->
                                        let
                                            (Solver solverTail) =
                                                oneOf s ss
                                        in
                                        solverTail stateA

                                    ISErr e ->
                                        IO.pure (ISErr e)
                            )


backtrack : Solver a
backtrack =
    Solver <|
        \state ->
            IO.pure (ISBack state)


foldM : (b -> a -> Solver b) -> b -> List a -> Solver b
foldM f b =
    List.foldl (\a -> bind (\acc -> f acc a)) (pure b)



-- ENCODERS and DECODERS


envEncoder : Env -> Encode.Value
envEncoder (Env cache manager connection registry) =
    Encode.object
        [ ( "cache", Stuff.packageCacheEncoder cache )
        , ( "manager", Http.managerEncoder manager )
        , ( "connection", connectionEncoder connection )
        , ( "registry", Registry.registryEncoder registry )
        ]


envDecoder : Decode.Decoder Env
envDecoder =
    Decode.map4 Env
        (Decode.field "cache" Stuff.packageCacheDecoder)
        (Decode.field "manager" Http.managerDecoder)
        (Decode.field "connection" connectionDecoder)
        (Decode.field "registry" Registry.registryDecoder)


connectionEncoder : Connection -> Encode.Value
connectionEncoder connection =
    case connection of
        Online manager ->
            Encode.object
                [ ( "type", Encode.string "Online" )
                , ( "manager", Http.managerEncoder manager )
                ]

        Offline ->
            Encode.object
                [ ( "type", Encode.string "Offline" )
                ]


connectionDecoder : Decode.Decoder Connection
connectionDecoder =
    Decode.field "type" Decode.string
        |> Decode.andThen
            (\type_ ->
                case type_ of
                    "Online" ->
                        Decode.map Online (Decode.field "manager" Http.managerDecoder)

                    "Offline" ->
                        Decode.succeed Offline

                    _ ->
                        Decode.fail ("Failed to decode Connection's type: " ++ type_)
            )
