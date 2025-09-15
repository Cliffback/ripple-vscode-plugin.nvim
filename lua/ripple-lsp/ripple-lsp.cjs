#!/usr/bin/env node

const { createConnection, createServer, createTypeScriptProject, loadTsdkByPath } =
  require(require.resolve('@volar/language-server/node', { paths: [process.cwd()] }));

const { pathToFileURL } = require('url');
const path = require('path');

// Pull BOTH language + TS plugin factories from the extension, not just language.js
const extRoot = (() => {
  const extRootIndex = process.argv.indexOf('--extRoot');
  return extRootIndex !== -1 && process.argv[extRootIndex + 1]
    ? process.argv[extRootIndex + 1]
    : null; // Default to null if not provided
})();

const { getRippleLanguagePlugin, createRippleDiagnosticPlugin } =
  require(path.join(extRoot, 'language.js'));
const { createTypeScriptPlugins } =
  require(path.join(extRoot, 'ts.js')); 

const connection = createConnection();
const server = createServer(connection);

const log = (...args) => console.error('[Ripple LSP]', ...args); 

function must(value, name) {
  if (!value) throw new Error(`${name} is required`);
  return value;
}

connection.onInitialize(async (params) => {
  try {
    const ripplePath = must(
      params.initializationOptions?.ripplePath || process.env.RIPPLE_COMPILER_PATH,
      'initializationOptions.ripplePath'
    );

    const tsdkPath = must(
      params.initializationOptions?.typescript?.tsdk || process.env.TSDK_PATH,
      'initializationOptions.typescript.tsdk'
    );

    const ripple = await import(pathToFileURL(path.resolve(ripplePath)).href);
    const { typescript, diagnosticMessages } =
      loadTsdkByPath(path.resolve(tsdkPath), params.locale ?? 'en');

    return server.initialize(
      params,
      createTypeScriptProject(typescript, diagnosticMessages, () => ({
        languagePlugins: [getRippleLanguagePlugin(ripple)],
        setup() {},
      })),
      // Use the extension’s TypeScript plugins + your diagnostics plugin
      [...createTypeScriptPlugins(typescript), createRippleDiagnosticPlugin()]
    );
  } catch (e) {
    log('Failed during onInitialize:', e);
    throw e;
  }
});

connection.onInitialized(() => {
  server.initialized();
  server.fileWatcher.watchFiles(['**/*.ripple']);
});

connection.listen();

