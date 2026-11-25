#ifndef GoLens_Bridging_Header_h
#define GoLens_Bridging_Header_h

#include <stdint.h>
#include <stdbool.h>
#include <util.h>

// FFI Callback types
// Log lines: stream is 1 for stdout and core messages, 2 for a running program's stderr.
typedef void (*SwiftCallback)(const char* msg, int stream);
typedef void (*DiagnosticsCallback)(const char* path, const char* jsonPayload);
typedef void (*LSPResponseCallback)(const char* jsonPayload);
typedef void (*DebugEventCallback)(const char* event, const char* jsonPayload);

// Go Backend Exports
void RegisterCallback(SwiftCallback cb);
void RegisterDiagnosticsCallback(DiagnosticsCallback cb);
void RegisterLSPResponseCallback(LSPResponseCallback cb);
void RegisterDebugEventCallback(DebugEventCallback cb);

// Status events: topic and JSON payload are valid only during the call.
typedef void (*StatusEventCallback)(const char* topic, const char* jsonPayload);
void RegisterStatusEventCallback(StatusEventCallback cb);

// Vsock Stream Bridge: Swift registers callback returning dup'd POSIX fd of VZVirtioSocketConnection.
// Returns fd >= 0 on success, -1 on timeout/connection failure, -2 if Micro-VM is not running.
typedef int (*VsockDialCallback)(uint32_t port);
void RegisterSandboxVsockDialer(VsockDialCallback cb);
typedef int (*VsockTimeoutDialCallback)(uint32_t port, uint32_t timeoutMs);
void RegisterSandboxVsockTimeoutDialer(VsockTimeoutDialCallback cb);
void RestartLanguageServer(void);
char* FindTool(const char* name);
char* CheckGoSyntax(const char* path, const char* source, int length);

char* DebugStart(char* configJson);
void DebugConfigurationDone(void);
void DebugStop(void);
void DebugContinue(int threadId);
void DebugPause(int threadId);
char* DebugGoroutineDump(const char* cRoot);
char* DebugSetFunctionBreakpoints(const char* cBreakpointsJson);
char* DebugRunToLine(const char* cFile, int line, const char* cBreakpointsJson, int threadId);
void DebugStepOver(int threadId);
void DebugStepInto(int threadId);
void DebugStepOut(int threadId);
char* DebugSetBreakpoints(const char* cFile, const char* cBreakpointsJson);
char* DebugSetVariable(int variablesReference, const char* name, const char* value);
char* DebugExceptionInfo(int threadId);
char* DebugGoroutineGroups(void);
char* DebugGetStackTrace(int threadId);
char* DebugGetScopes(int frameId);
char* DebugGetVariables(int variablesReference);
char* DebugGetThreads(void);
char* DebugEvaluate(const char* expression, int frameId);

void InitEditor(void);
void SetExecutionEnvironment(const char* mode);
void OpenWorkspace(const char* path);
void CloseWorkspace(void);
void CloseWorkspaceFolder(const char* path);
void ShutdownGoLensCore(void);

// LSP document sync: text arguments are (bytes, length), read only during the call.
void NotifyFileOpen(const char* path, const char* text, int length);
int NotifyIncrementalChange(const char* path, int startByte, int endByte, const char* text, int length, int expectedLength);
int NotifyFullChange(const char* path, const char* text, int length);
void NotifyFileClose(const char* path);

int SendLSPMessage(const char* jsonMsg);
void CancelLSPRequest(long long requestId);
int GuestMemoryPressure(void);
// Usage index: JSON {state, reason?, counts?: [{line, col, count}]}, freed with FreeGoCString; call off the main thread.
char* UsageCounts(const char* path);
void SetUsageIndexEnabled(int enabled);
int GuestMemoryStepTarget(int currentMB, int baseMB, int ceilingMB, int idle);
void GuestMemoryStepApplied(int stepMB, int ceilingMB);
void ExecuteGoRun(char* configJson);
char* DiscoverGoTests(const char* dir);

// go test -json runner: results arrive as JSON on the test event callback, valid only during the call.
typedef void (*TestEventCallback)(const char* jsonPayload);
void RegisterTestEventCallback(TestEventCallback cb);
long long RunTests(const char* requestJson);
void StopTestRun(long long runId);
void WriteProgramStdin(long long runId, const char* input, int length);
void CloseProgramStdin(long long runId);
void StopProgramRun(long long runId);
void RunGoCommand(char* args);
long long RunExternalCommand(const char* argvJSON, const char* dir, const char* title, const char* key);
char* InspectDockerfile(const char* path, const char* content);
char* DockerEngineStatus(const char* dir);
char* ValidateComposeFile(const char* composePath);
char* ComposeServices(const char* root, const char* file);
char* RemoteCheckTarget(const char* root, const char* targetJSON);
long long RemoteFix(const char* root, const char* targetJSON, const char* fix);
char* GenerateDockerfile(const char* contextDir, const char* optionsJSON);
char* SqlcQueryForGo(const char* genPath, int line, const char* root, const char* overlaysJSON);
char* SqlcQueriesInFile(const char* sqlPath, const char* content, const char* root, const char* overlaysJSON);
char* ToolchainHealth(const char* root);
char* AllowAutomaticToolchain(void);
void SetHostGoBinary(const char* goBinaryPath);
char* FileTests(const char* path);
char* ResolveCaretTestTarget(const char* path, int line);
char* UntestedPackageFunctions(const char* pkgDir);
char* InlineValueLines(const char* path, int line, const char* namesJson);
char* DeclarationAt(const char* path, int byteOffset);
char* GoDeclarations(const char* source);
char* InspectGoFuncSignature(const char* path, const char* src, int offset);
char* ApplyGoChangeSignature(const char* reqJson);
char* GenerateGoCode(const char* reqJson);
void SetGoplsBuildTarget(const char* goos, const char* goarch, const char* tags);
char* CheckGoBuildTarget(const char* path, const char* content, const char* goos, const char* goarch, const char* tags);
char* RunGoSafetyAudit(const char* workspaceDir, const char* consoleOutput);
char* RunGolangCILintPackage(const char* workspaceRoot, const char* packageDir);
char* RunGoSafetyAnalyzers(const char* workspaceRoot, const char* packageDir, const char* disabledCategories);
char* ListGoProcesses(void);
char* ParseGoProfileFile(const char* path);
char* ParseGoProfileDetailed(const char* path, const char* sampleType);
char* GoSyntaxSelectionRanges(const char* src, int offset);
char* ListGoWorkspaceInterfaces(const char* workspaceDir, const char* currentPath);
char* ModifyGoStructTags(const char* reqJson);
char* ConvertJSONToGoStruct(const char* reqJson);
char* InspectGoModFile(const char* path, const char* content, int checkUpdates);
char* InspectGoStructLayout(const char* path, const char* src, int offset, const char* goarch);
char* ApplyGoASTIntention(const char* reqJson);
char* InspectGoExtractMethod(const char* reqJson);
char* ApplyGoExtractMethod(const char* reqJson);
char* ApplyGoExtractVariable(const char* reqJson);
char* ApplyGoInlineVariable(const char* reqJson);
char* GenerateGoTableDrivenTest(const char* reqJson);
void ExecuteGoProfileApp(char* configJson);
char* AnalyzeGoEscape(const char* workspacePath, const char* filePath);
char* DisassembleGoFunction(const char* pkgDir, const char* funcName, const char* arch);
char* ScanGoGenerateFile(const char* filePath, const char* src);
char* SearchGoWorkspaceSymbols(const char* workspacePath, const char* query, int limit);
void InvalidateWorkspaceSymbolFile(const char* path);
char* InspectGoExtractType(const char* reqJson);
char* ApplyGoExtractType(const char* reqJson);
char* PropagateGoInterfaceMethods(const char* reqJson);
char* GenerateGoInterfaceMock(const char* dir, const char* file, int line, int col, const char* ifaceName, const char* mockName);
char* FillGoStructFields(const char* dir, const char* filePath, const char* content, int line, int col);
extern char* InspectGoEnumMethods(char* cDir, char* cFile, char* cContent, int line, int col, char* cTypeName, int trimPrefix, int includeParse, int includeIsValid, int includeValues);
extern char* InspectGoStructConstructor(char* cDir, char* cFile, char* cContent, int line, int col, char* cStructName, int includeOptions, int returnPointer);
extern char* InspectGoFuzzTest(char* cDir, char* cFile, char* cContent, int line, int col, char* cFuncName, int includeEdgeSeeds, int checkDeterminism);
char* GetGoRuntimeDiagnostics(void);
void ReleaseGoMemory(void);
char* CompareGoBenchmarks(const char* baselineInput, const char* currentInput);
char* InspectGoPackageDeps(const char* workspaceDir);
char* InspectGoFunctionComplexity(const char* cDir, const char* cFile, const char* cContent, int includeWorkspace);

// Project search: batches stream as JSON on the search callback, valid only during the call.
typedef void (*SearchCallback)(const char* jsonPayload);
void RegisterSearchCallback(SearchCallback cb);
long long StartProjectSearch(const char* root, const char* query);
void CancelProjectSearch(void);
char* ListProjectFiles(const char* root);

// Terminal backend: data arrives as (bytes, length), valid only during the callback.
typedef void (*TerminalCallback)(const char* termId, const char* data, int length);
void RegisterTerminalCallback(TerminalCallback cb);

void StartTerminal(const char* termId, const char* cwd);
void WriteTerminal(const char* termId, const char* input, int length);
void ResizeTerminal(const char* termId, int rows, int cols);
void CloseTerminal(const char* termId);
char* CreateFileOrFolder(const char* path, int isFolder);

// Every char* returned below is freed with FreeGoCString; GetSemanticTokens buffers with FreeGoBuffer.
void FreeGoCString(char* ptr);
void FreeGoBuffer(void* ptr);
char* RunGitCommand(const char* workspacePath, const char* argsJson, const char* input, int inputLen);
void* RunGitCommandEx(long long id, const char* root, const char* dir, const char* argsJson, const char* input, int inputLen, long long maxOutput, long long* outLen);
void CancelGitCommand(long long id);
void SetGitCredentialsJSON(const char* credentialsJson);
char* DiscoverSSHSigningKeysJSON(const char* extraPathsJson);
void* RunSignedGitCommitEx(long long id, const char* root, const char* dir, const char* keyPath, const char* message, int amend, long long* outLen);
void* RunSignedGitTagEx(long long id, const char* root, const char* dir, const char* keyPath, const char* tagName, const char* revision, const char* message, long long* outLen);
char* VerifyGitCommitSignatureJSON(const char* rawCommit, int rawLen, const char* allowedSignersPath);
char* WriteGitAllowedSigners(const char* path, const char* email, const char* pubKey);
void SetVisibleDocuments(const char* paths);
int32_t* GetSemanticTokens(const char* path, int startByte, int endByte, int* outCount);
char* GetSignatureHelp(const char* path, int byteOffset);
char* RenameSymbol(const char* path, int byteOffset, const char* newName);
char* FormattingEdits(const char* path, int tabSize);
char* OrganizeImportsEdits(const char* path);
char* ExpandLiveTemplate(const char* body, const char* indent, const char* selection);
char* CompletionStart(const char* path, int caretByte, int triggerKind, const char* triggerCharacter);
char* CompletionFilter(long long session, const char* path, int caretByte, const char* query);
char* CompletionDoc(long long session, int index);
char* CompletionCommit(long long session, int index, int caretByte);
void CompletionCancel(void);

// LSP commands, code lenses and code actions return JSON {result|error} freed with FreeGoCString.
typedef void (*ApplyEditCallback)(long long token, const char* jsonPayload);
void RegisterApplyEditCallback(ApplyEditCallback cb);
void ApplyEditResult(long long token, int applied, const char* reason);
char* CodeLenses(const char* path);
char* ModuleNotes(const char* goModPath);
void SetGoplsOptions(const char* optionsJson);
char* ExecuteCommand(const char* paramsJson);
char* ResolveCommand(const char* paramsJson);
char* ListEnum(const char* source, const char* configJson, const char* query);
char* CodeActions(const char* path, int startByte, int endByte, const char* only, const char* diagnosticsJson);
char* ResolveCodeAction(const char* actionJson);
char* InspectGoBenchmarkGen(const char* dir, const char* file, const char* content, int line, int col, const char* funcName, int reportAllocs, int runParallel, int tableSubBench);

char* ContextualASTQuickFixes(const char* filePath, const char* content, int line);
char* InspectRawVariablePayload(const char* typ, const char* value);
char* ParseGoTraceFile(const char* tracePath);
char* BuildGoMultiBuffer(const char* query, const char* dir, const char* filesJson);
char* BuildGoMultiBufferFromLocations(const char* dir, const char* locationsJson, int contextLines);
char* ApplyGoMultiBufferEdits(const char* editsJson);
char* ScanGoHTTPRoutes(const char* src);
char* ExecuteGoHTTPRequest(const char* url, const char* method, const char* headersJson, const char* body, int timeoutSec);
char* HTTPFileOutline(const char* path, const char* content, const char* workspaceRoot);
char* HTTPFileRun(const char* inputJson);
int HTTPFileCancel(const char* runId);

// Database tools: JSON results are freed with FreeGoCString, DBFetchPage buffers with FreeGoBuffer.
// "database" status events carry statementStarted, statementFinished, fetchProgress and sessionState.
char* DBConfigure(const char* workspaceRoot, const char* dataSourcesJSON);
char* DBSetSecret(const char* dataSourceId, const char* secret);
void DBShutdownWorkspace(const char* workspaceRoot);
char* DBStats(void);
char* DBTestConnection(const char* requestJSON);
char* DBDisconnect(const char* dataSourceId);
char* DBCloseConsole(const char* consoleId, int force);
char* DBStatements(const char* text, const char* dialect);
char* DBExecute(const char* requestJSON);
int DBCancel(const char* id);
uint8_t* DBFetchPage(const char* resultId, int64_t firstRow, int32_t maxRows, int64_t* outLen);
char* DBFetchAll(const char* resultId);
char* DBSortResult(const char* resultId, const char* sortJSON);
char* DBCellValue(const char* resultId, int64_t row, int32_t column, int32_t maxBytes);
void DBCloseResult(const char* resultId);
char* DBIntrospect(const char* requestJSON);
char* DBSchemaChildren(const char* requestJSON);
char* DBComplete(const char* requestJSON);
char* DBOpenTable(const char* requestJSON);
char* DBCountRows(const char* requestJSON);
char* DBPlanEdits(const char* requestJSON);
char* DBApplyEdits(const char* requestJSON);
char* DBTransaction(const char* requestJSON);
char* DBExplain(const char* requestJSON);
char* DBExport(const char* requestJSON);
char* DBDetectDataSources(const char* workspaceRoot);
char* DBParameters(const char* text, const char* dialect, int64_t startByte, int64_t endByte);
char* DBHistory(const char* requestJSON);
char* DBSetHistoryDirectory(const char* directory);
char* DBGoSQLSites(const char* path, const char* content, const char* root);
char* DBSqlcQuery(const char* sqlPath, const char* content, int line);
char* DBRelatedRows(const char* requestJSON);

// Docker services: JSON results are freed with FreeGoCString; shapes are in core/docker/testdata/ffi.
// Status topics "services.docker.batch" (DockerWatchStart) and "services.docker.logs" (DockerLogsOpen).
long long DockerWatchStart(const char* kindsJSON);
void DockerWatchStop(long long watchId);
char* DockerContainerAction(const char* containerId, const char* action);
char* DockerContainerInspect(const char* containerId);
long long DockerLogsOpen(const char* idsJSON, int tail);
void DockerLogsClose(long long streamId);
char* DockerList(const char* kind);
char* DockerRemove(const char* kind, const char* id);
long long DockerComposeLogsRun(const char* composePath, const char* title, const char* key);
void StartTerminalCommand(const char* termId, const char* cwd, const char* argvJSON);

// Docker networks (DockerList and DockerRemove with "network"), disk usage and prune, selected-container stats and contexts.
// Status topic "services.docker.stats" (DockerStatsStart).
char* DockerDiskUsage(void);
char* DockerPrune(const char* optionsJSON);
long long DockerStatsStart(const char* containerId);
void DockerStatsStop(long long streamId);
char* DockerContexts(void);
char* DockerUseContext(const char* name);

char* KubeContexts(void);
char* KubeNamespaces(const char* context);
long long KubeWatchStart(const char* context, const char* ns, const char* kindsJSON);
void KubeWatchStop(long long watchId);
char* KubeDetails(const char* context, const char* ns, const char* kind, const char* name);
long long KubeLogsOpen(const char* context, const char* ns, const char* pod, const char* container, int previous, int tail);
void KubeLogsClose(long long streamId);
char* KubeDeletePod(const char* context, const char* ns, const char* name);
char* KubeRolloutRestart(const char* context, const char* ns, const char* name);

extern char* DocsListPackages(const char* reqID, const char* root, const char* targetJSON);
extern char* DocsPackagePage(const char* reqID, const char* root, const char* importPath, const char* targetJSON, const char* overlayJSON);
extern char* DocsSearch(const char* reqID, const char* root, const char* targetJSON, const char* query, int limit);
extern void DocsCancel(const char* reqID);
extern void DocsInvalidate(const char* root);

#endif /* GoLens_Bridging_Header_h */
