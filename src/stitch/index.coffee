_   = require 'underscore'
fs  = require 'fs'
sys = require 'sys'

{extname, join, normalize} = require 'path'

defaultCompilers =
  js: (module, filename) ->
    content = fs.readFileSync filename, 'utf8'
    module._compile content, filename

try
  CoffeeScript = require 'coffee-script'
  defaultCompilers.coffee = (module, filename) ->
    content = CoffeeScript.compile fs.readFileSync filename, 'utf8'
    module._compile content, filename
catch err

forEachAsync = (elements, callback) ->
  remainingCount = elements.length

  if remainingCount is 0
    return callback null, null

  next = () ->
    remainingCount--
    if remainingCount <= 0
      callback null, null

  for element in elements
    callback next, element

mtimeCache = {}

exports.walkTree = walkTree = (directory, callback) ->
  fs.readdir directory, (err, files) ->
    if err then return callback err

    forEachAsync files, (next, file) ->
      if next
        return next() if file.match /^\./
        filename = join directory, file

        fs.stat filename, (err, stats) ->
          mtimeCache[filename] = stats?.mtime?.toString()

          if !err and stats.isDirectory()
            walkTree filename, (err, filename) ->
              if filename
                callback err, filename
              else
                next()
          else
            callback err, filename
            next()
      else
        callback err, null

exports.getFilesInTree = getFilesInTree = (directory, callback) ->
  files = []
  walkTree directory, (err, filename) ->
    if err
      callback err
    else if filename
      files.push filename
    else
      callback err, files.sort()

getCompilersFrom = (options) ->
  _.extend {}, defaultCompilers, options.compilers

compilerIsAvailableFor = (filename, options) ->
  for name in Object.keys getCompilersFrom options
    extension = extname(filename).slice(1)
    return true if name is extension
  false

compileCache = {}

getCompiledSourceFromCache = (path) ->
  if cache = compileCache[path]
    if mtimeCache[path] is cache.mtime
      cache.source

putCompiledSourceToCache = (path, source) ->
  if mtime = mtimeCache[path]
    compileCache[path] = {mtime, source}

exports.compileFile = compileFile = (path, options, callback) ->
  if options.cache and source = getCompiledSourceFromCache path
    callback null, source
  else
    compilers = getCompilersFrom options
    extension = extname(path).slice(1)

    if compile = compilers[extension]
      source = null
      mod =
        _compile: (content, filename) ->
          source = content

      try
        compile mod, path
        putCompiledSourceToCache path, source if options.cache
        callback null, source
      catch err
        if err instanceof Error
          err.message = "can't compile #{path}\n#{err.message}"
        else
          err = new Error "can't compile #{path}\n#{err}"
        callback err
    else
      callback "no compiler for '.#{extension}' files"


expandPaths = (sourcePaths, callback) ->
  paths = []

  forEachAsync sourcePaths, (next, sourcePath) ->
    if next
      fs.realpath sourcePath, (err, path) ->
        if err
          callback err
        else
          paths.push normalize path
        next()
    else
      callback null, paths

stripExtension = (filename) ->
  extension = extname filename
  filename.slice 0, -extension.length


exports.Package = class Package
  constructor: (config) ->
    @identifier = config.identifier ? 'require'
    @paths      = config.paths ? ['lib']

  compile: (callback) ->
    @gatherSources (err, sources) =>
      if err
        callback err
      else
        result = """
          var #{@identifier} = (function(modules) {
            var exportCache = {};
            return function require(name) {
              var module = exportCache[name];
              var fn;
              if (module) {
                return module;
              } else if (fn = modules[name]) {
                module = { id: name, exports: {} };
                fn(module.exports, require, module);
                exportCache[name] = module.exports;
                return module.exports;
              } else {
                throw 'module \\'' + name + '\\' not found';
              }
            }
          })({
        """

        index = 0
        for name, {filename, source} of sources
          result += if index++ is 0 then "" else ", "
          result += sys.inspect name
          result += ": function(exports, require, module) {#{source}}"

        result += """
          });\n
        """

        callback null, result


  gatherSources: (callback) ->
    sources = {}

    forEachAsync @paths, (next, sourcePath) =>
      if next
        @gatherSourcesFromPath sourcePath, (err, pathSources) ->
          if err then callback err
          else
            for key, value of pathSources
              sources[key] = value
          next()
      else
        callback null, sources

  gatherSourcesFromPath: (sourcePath, callback) ->
    options =
      paths: @paths

    fs.stat sourcePath, (err, stat) =>
      if err then return callback err

      sources = {}

      if stat.isDirectory()
        getFilesInTree sourcePath, (err, paths) =>
          if err then callback err
          else
            forEachAsync paths, (next, path) =>
              if next
                if compilerIsAvailableFor path, options
                  @gatherSource path, (err, key, value) ->
                    if err then callback err
                    else sources[key] = value
                    next()
                else
                  next()
              else
                callback null, sources
      else
        @gatherSource sourcePath, (err, key, value) ->
          if err then callback err
          else sources[key] = value
          callback null, sources

  gatherSource: (path, callback) ->
    options =
      paths: @paths

    @getRelativePath path, (err, relativePath) ->
      if err then callback err
      else
        compileFile path, options, (err, source) ->
          if err then callback err
          else
            callback err, stripExtension(relativePath),
              filename: relativePath
              source:   source

  getRelativePath: (path, callback) ->
    path = normalize path

    expandPaths @paths, (err, expandedPaths) ->
      return callback err if err

      fs.realpath path, (err, path) ->
        return callback err if err

        for expandedPath in expandedPaths
          base = expandedPath + "/"
          if path.indexOf(base) is 0
            return callback null, path.slice base.length

        callback "#{path} isn't in the require path"




exports.createPackage = (config) ->
  new Package config
