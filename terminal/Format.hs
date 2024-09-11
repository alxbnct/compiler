{-# LANGUAGE OverloadedStrings #-}

module Format
  ( Flags (..),
    run,
    formatByteString,
  )
where

import Control.Monad (filterM, when)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as B
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (mapMaybe)
import Data.NonEmptyList qualified as NE
import Directories qualified as Dirs
import File qualified
import Gren.Format qualified as Format
import Gren.Format.Normalize qualified as Normalize
import Gren.Outline qualified as Outline
import Parse.Module qualified as Parse
import Reporting qualified
import Reporting.Doc qualified as D
import Reporting.Error.Syntax qualified as Syntax
import Reporting.Exit qualified as Exit
import Reporting.Exit.Help qualified as Help
import Reporting.Task qualified as Task
import System.Directory qualified as Dir
import System.FilePath ((</>))
import System.FilePath qualified as FilePath

-- FLAGS

data Flags = Flags
  { _skipPrompts :: Bool,
    _stdin :: Bool,
    _validate :: Bool
  }

-- RUN

run :: [FilePath] -> Flags -> IO ()
run paths flags = do
  let action = if _validate flags then validate else format flags
  Reporting.attempt Exit.formatToReport $
    Task.run (action =<< getEnv paths flags)

-- FORMATTING RESULT

data FormattingResult
  = FormattingSuccess FormattingChange BSL.ByteString
  | FormattingFailure (Maybe FilePath) BS.ByteString Syntax.Error

data FormattingChange = Changed | NotChanged

-- ENV

data Env = Env
  { _inputs :: Inputs
  }

data Inputs
  = Stdin
  | Files [FilePath]
  | Project Parse.ProjectType [FilePath]

getEnv :: [FilePath] -> Flags -> Task.Task Exit.Format Env
getEnv paths flags =
  Env <$> (resolveInputPaths paths flags)

resolveInputPaths :: [FilePath] -> Flags -> Task.Task Exit.Format Inputs
resolveInputPaths paths flags =
  case (_stdin flags, paths) of
    (True, []) ->
      return Stdin
    (True, _ : _) ->
      Task.throw Exit.FormatStdinWithFiles
    (False, []) ->
      do
        (projectType, files) <- sourceDirsFromGrenJson
        resolvedFiles <- resolveFiles files
        return $ Project projectType resolvedFiles
    (False, somePaths) ->
      Files <$> (resolveFiles somePaths)

sourceDirsFromGrenJson :: Task.Task Exit.Format (Parse.ProjectType, [FilePath])
sourceDirsFromGrenJson =
  do
    root <- Task.mio Exit.FormatNoOutline Dirs.findRoot
    outline <- Task.eio Exit.FormatBadOutline $ Outline.read root
    Task.io $
      do
        paths <- filterM Dir.doesDirectoryExist $ Outline.toGiven <$> (NE.toList $ Outline.sourceDirs outline)
        return $ case outline of
          Outline.App _ ->
            ( Parse.Application,
              paths
            )
          Outline.Pkg pkgOutline ->
            ( Parse.Package $ Outline._pkg_name pkgOutline,
              paths
            )

resolveFiles :: [FilePath] -> Task.Task Exit.Format [FilePath]
resolveFiles paths =
  concat <$> mapM resolveFile paths

resolveFile :: FilePath -> Task.Task Exit.Format [FilePath]
resolveFile path =
  do
    isDir <- Task.io (Dir.doesDirectoryExist path)
    if isDir
      then resolveFiles =<< Task.io (fmap (path </>) . filter (not . ignore) <$> Dir.listDirectory path)
      else
        if FilePath.takeExtension path == ".gren"
          then return [path]
          else return []
  where
    ignore dir =
      dir == ".gren"
        || dir == "node_modules"
        || dir == ".git"

-- FORMAT

format :: Flags -> Env -> Task.Task Exit.Format ()
format flags (Env inputs) =
  case inputs of
    Stdin -> do
      formattingResult <- formatByteStringWithPath Parse.Application Nothing <$> Task.io BS.getContents
      case formattingResult of
        FormattingFailure path source e ->
          Task.throw $ Exit.FormatErrors (NE.singleton $ Exit.FormattingFailureParseError path source e)
        FormattingSuccess _ formatted ->
          Task.io $ BSL.putStr formatted
    Files paths ->
      formatFilesOnDisk flags Parse.Application paths
    Project projectType paths ->
      formatFilesOnDisk flags projectType paths

validate :: Env -> Task.Task Exit.Format ()
validate (Env inputs) = do
  case inputs of
    Stdin -> do
      result <- formatByteStringWithPath Parse.Application Nothing <$> Task.io BS.getContents
      throwIfHasValidateErrors [result]
    Files paths ->
      validateFiles Parse.Application paths
    Project projectType paths ->
      validateFiles projectType paths

validateFiles :: Parse.ProjectType -> [FilePath] -> Task.Task Exit.Format ()
validateFiles projectType paths = do
  Task.io $ putStrLn ""
  results <- mapM (validateFile projectType) paths
  Task.io $ putStrLn ""
  throwIfHasValidateErrors results

throwIfHasValidateErrors :: [FormattingResult] -> Task.Task Exit.Format ()
throwIfHasValidateErrors results =
  sequence_ $ (Task.throw . Exit.FormatValidateErrors) <$> NE.fromList (mapMaybe validateFailure results)

validateFailure :: FormattingResult -> Maybe Exit.ValidateFailure
validateFailure formattingResult =
  case formattingResult of
    (FormattingFailure path source err) ->
      Just (Exit.VaildateFormattingFailure $ Exit.FormattingFailureParseError path source err)
    FormattingSuccess Changed _ ->
      Just Exit.ValidateNotCorrectlyFormatted
    FormattingSuccess NotChanged _ ->
      Nothing

validateFile :: Parse.ProjectType -> FilePath -> Task.Task Exit.Format FormattingResult
validateFile projectType path =
  assertFileExists path >> Task.io (validateExistingFile projectType path)

validateExistingFile :: Parse.ProjectType -> FilePath -> IO FormattingResult
validateExistingFile projectType path = do
  putStr ("Validating " ++ path)
  formattingResult <- formatByteStringWithPath projectType (Just path) <$> File.readUtf8 path
  case formattingResult of
    FormattingFailure _ _ _ ->
      Help.toStdout (" " <> D.red "(parse error)" <> "\n")
    FormattingSuccess NotChanged _ ->
      Help.toStdout (" " <> D.green "VALID" <> "\n")
    FormattingSuccess Changed _ -> do
      Help.toStdout (" " <> D.red "INVALID" <> "\n")
  pure formattingResult

formatFilesOnDisk :: Flags -> Parse.ProjectType -> [FilePath] -> Task.Task Exit.Format ()
formatFilesOnDisk flags projectType paths = do
  approved <- Task.io $ Reporting.ask (_skipPrompts flags) (confirmFormat paths)
  if not approved
    then Task.io $ putStrLn "Okay, I did not change anything!"
    else do
      Task.io $ putStrLn ""
      results <- mapM (formatFile projectType) paths
      Task.io $ putStrLn ""
      throwIfHasFormattingErrors results

throwIfHasFormattingErrors :: [FormattingResult] -> Task.Task Exit.Format ()
throwIfHasFormattingErrors results =
  sequence_ $ (Task.throw . Exit.FormatErrors) <$> NE.fromList (mapMaybe formattingError results)

formattingError :: FormattingResult -> Maybe Exit.FormattingFailure
formattingError (FormattingFailure path source err) = Just (Exit.FormattingFailureParseError path source err)
formattingError _ = Nothing

confirmFormat :: [FilePath] -> D.Doc
confirmFormat paths =
  D.stack
    [ D.reflow "This will overwrite the following files to use Gren's preferred style:",
      D.indent 4 $ D.vcat (fmap D.fromChars paths),
      D.reflow "This cannot be undone! Make sure to back up these files before proceeding.",
      D.reflow
        "Are you sure you want to overwrite these files with formatted versions? [Y/n]: "
    ]

formatFile :: Parse.ProjectType -> FilePath -> Task.Task Exit.Format FormattingResult
formatFile projectType path =
  assertFileExists path >> Task.io (formatExistingFile projectType path)

formatExistingFile :: Parse.ProjectType -> FilePath -> IO FormattingResult
formatExistingFile projectType path = do
  putStr ("Formatting " ++ path)
  formattingResult <- formatByteStringWithPath projectType (Just path) <$> File.readUtf8 path
  case formattingResult of
    FormattingFailure _ _ _ ->
      Help.toStdout (" " <> D.red "(parse error)" <> "\n")
    FormattingSuccess NotChanged _ ->
      Help.toStdout (" " <> D.dullwhite "(no changes)" <> "\n")
    FormattingSuccess Changed formatted -> do
      BSL.writeFile path formatted
      Help.toStdout (" " <> D.green "CHANGED" <> "\n")
  pure formattingResult

formatByteStringWithPath :: Parse.ProjectType -> Maybe FilePath -> BS.ByteString -> FormattingResult
formatByteStringWithPath projectType maybePath original =
  let formattedResult = B.toLazyByteString <$> formatByteString projectType original
   in case formattedResult of
        Left e -> FormattingFailure maybePath original e
        Right formatted
          | formatted == BSL.fromStrict original -> FormattingSuccess NotChanged formatted
          | otherwise -> FormattingSuccess Changed formatted

formatByteString :: Parse.ProjectType -> BS.ByteString -> Either Syntax.Error B.Builder
formatByteString projectType original =
  Format.toByteStringBuilder . Normalize.normalize projectType <$> Parse.fromByteString projectType original

assertFileExists :: FilePath -> Task.Task Exit.Format ()
assertFileExists path = do
  exists <- Task.io (Dir.doesFileExist path)
  when (not exists) $
    Task.throw (Exit.FormatPathUnknown path)
