require '../src/window'
window.setUpEnvironment('spec')
atom.restoreDimensions()

require '../vendor/jasmine-jquery'
path = require 'path'
{_, $, File, RootView, fs} = require 'atom'
Keymap = require '../src/keymap'
Config = require '../src/config'
{Point} = require 'telepath'
Project = require '../src/project'
EditorView = require '../src/editor-view'
TokenizedBuffer = require '../src/tokenized-buffer'
pathwatcher = require 'pathwatcher'
platform = require './spec-helper-platform'
clipboard = require 'clipboard'

platform.generateEvilFiles()

atom.themes.loadBaseStylesheets()
atom.themes.requireStylesheet '../static/jasmine'

fixturePackagesPath = path.resolve(__dirname, './fixtures/packages')
atom.packages.packageDirPaths.unshift(fixturePackagesPath)
atom.keymap.loadBundledKeymaps()
keyBindingsToRestore = atom.keymap.getKeyBindings()

$(window).on 'core:close', -> window.close()
$(window).on 'unload', ->
  atom.windowMode = 'spec'
  atom.getWindowState().set('dimensions', atom.getDimensions())
  atom.saveWindowState()
$('html,body').css('overflow', 'auto')

jasmine.getEnv().addEqualityTester(_.isEqual) # Use underscore's definition of equality for toEqual assertions
jasmine.getEnv().defaultTimeoutInterval = 5000

specPackageName = null
specPackagePath = null
specProjectPath = null

{specDirectory, resourcePath} = atom.getLoadSettings()

if specDirectory
  specPackagePath = path.resolve(specDirectory, '..')
  try
    specPackageName = fs.readObjectSync(path.join(specPackagePath, 'package.json'))?.name
  specProjectPath = path.join(specDirectory, 'fixtures')

beforeEach ->
  $.fx.off = true
  projectPath = specProjectPath ? path.join(@specDirectory, 'fixtures')
  atom.project = atom.getWindowState().set('project', new Project(path: projectPath))
  atom.keymap.keyBindings = _.clone(keyBindingsToRestore)

  window.resetTimeouts()
  atom.packages.packageStates = {}
  spyOn(atom, 'saveWindowState')
  atom.syntax.clearGrammarOverrides()
  atom.syntax.clearProperties()

  spy = spyOn(atom.packages, 'resolvePackagePath').andCallFake (packageName) ->
    if specPackageName and packageName is specPackageName
      resolvePackagePath(specPackagePath)
    else
      resolvePackagePath(packageName)
  resolvePackagePath = _.bind(spy.originalValue, atom.packages)

  # prevent specs from modifying Atom's menus
  spyOn(atom.menu, 'sendToBrowserProcess')

  # reset config before each spec; don't load or save from/to `config.json`
  config = new Config({resourcePath,  configDirPath: atom.getConfigDirPath()})
  spyOn(config, 'load')
  spyOn(config, 'save')
  config.setDefaults('core', RootView.configDefaults)
  config.setDefaults('editor', EditorView.configDefaults)
  config.set "editor.fontFamily", "Courier"
  config.set "editor.fontSize", 16
  config.set "editor.autoIndent", false
  config.set "core.disabledPackages", ["package-that-throws-an-exception",
    "package-with-broken-package-json", "package-with-broken-keymap"]
  config.save.reset()
  atom.config = config

  # make editor display updates synchronous
  spyOn(EditorView.prototype, 'requestDisplayUpdate').andCallFake -> @updateDisplay()
  spyOn(RootView.prototype, 'setTitle').andCallFake (@title) ->
  spyOn(window, "setTimeout").andCallFake window.fakeSetTimeout
  spyOn(window, "clearTimeout").andCallFake window.fakeClearTimeout
  spyOn(File.prototype, "detectResurrectionAfterDelay").andCallFake -> @detectResurrection()

  # make tokenization synchronous
  TokenizedBuffer.prototype.chunkSize = Infinity
  spyOn(TokenizedBuffer.prototype, "tokenizeInBackground").andCallFake -> @tokenizeNextChunk()

  pasteboardContent = 'initial pasteboard content'
  spyOn(clipboard, 'writeText').andCallFake (text) -> pasteboardContent = text
  spyOn(clipboard, 'readText').andCallFake -> pasteboardContent

  addCustomMatchers(this)

afterEach ->
  atom.packages.deactivatePackages()
  atom.menu.template = []

  atom.rootView?.remove?()
  atom.rootView = null

  atom.project?.destroy?()
  atom.project = null

  $('#jasmine-content').empty() unless window.debugContent
  delete atom.windowState
  jasmine.unspy(atom, 'saveWindowState')
  ensureNoPathSubscriptions()
  atom.syntax.off()
  waits(0) # yield to ui thread to make screen update more frequently

ensureNoPathSubscriptions = ->
  watchedPaths = pathwatcher.getWatchedPaths()
  pathwatcher.closeAllWatchers()
  if watchedPaths.length > 0
    throw new Error("Leaking subscriptions for paths: " + watchedPaths.join(", "))

emitObject = jasmine.StringPrettyPrinter.prototype.emitObject
jasmine.StringPrettyPrinter.prototype.emitObject = (obj) ->
  if obj.inspect
    @append obj.inspect()
  else
    emitObject.call(this, obj)

jasmine.unspy = (object, methodName) ->
  throw new Error("Not a spy") unless object[methodName].originalValue?
  object[methodName] = object[methodName].originalValue

addCustomMatchers = (spec) ->
  spec.addMatchers
    toBeInstanceOf: (expected) ->
      notText = if @isNot then " not" else ""
      this.message = => "Expected #{jasmine.pp(@actual)} to#{notText} be instance of #{expected.name} class"
      @actual instanceof expected

    toHaveLength: (expected) ->
      if not @actual?
        this.message = => "Expected object #{@actual} has no length method"
        false
      else
        notText = if @isNot then " not" else ""
        this.message = => "Expected object with length #{@actual.length} to#{notText} have length #{expected}"
        @actual.length == expected

    toExistOnDisk: (expected) ->
      notText = this.isNot and " not" or ""
      @message = -> return "Expected path '" + @actual + "'" + notText + " to exist."
      fs.existsSync(@actual)

window.keyIdentifierForKey = (key) ->
  if key.length > 1 # named key
    key
  else
    charCode = key.toUpperCase().charCodeAt(0)
    "U+00" + charCode.toString(16)

window.keydownEvent = (key, properties={}) ->
  properties = $.extend({originalEvent: { keyIdentifier: keyIdentifierForKey(key) }}, properties)
  $.Event("keydown", properties)

window.mouseEvent = (type, properties) ->
  if properties.point
    {point, editorView} = properties
    {top, left} = @pagePixelPositionForPoint(editorView, point)
    properties.pageX = left + 1
    properties.pageY = top + 1
  properties.originalEvent ?= {detail: 1}
  $.Event type, properties

window.clickEvent = (properties={}) ->
  window.mouseEvent("click", properties)

window.mousedownEvent = (properties={}) ->
  window.mouseEvent('mousedown', properties)

window.mousemoveEvent = (properties={}) ->
  window.mouseEvent('mousemove', properties)

window.waitsForPromise = (args...) ->
  if args.length > 1
    { shouldReject, timeout } = args[0]
  else
    shouldReject = false
  fn = _.last(args)

  window.waitsFor timeout, (moveOn) ->
    promise = fn()
    if shouldReject
      promise.fail(moveOn)
      promise.done ->
        jasmine.getEnv().currentSpec.fail("Expected promise to be rejected, but it was resolved")
        moveOn()
    else
      promise.done(moveOn)
      promise.fail (error) ->
        jasmine.getEnv().currentSpec.fail("Expected promise to be resolved, but it was rejected with #{jasmine.pp(error)}")
        moveOn()

window.resetTimeouts = ->
  window.now = 0
  window.timeoutCount = 0
  window.timeouts = []

window.fakeSetTimeout = (callback, ms) ->
  id = ++window.timeoutCount
  window.timeouts.push([id, window.now + ms, callback])
  id

window.fakeClearTimeout = (idToClear) ->
  window.timeouts = window.timeouts.filter ([id]) -> id != idToClear

window.advanceClock = (delta=1) ->
  window.now += delta
  callbacks = []

  window.timeouts = window.timeouts.filter ([id, strikeTime, callback]) ->
    if strikeTime <= window.now
      callbacks.push(callback)
      false
    else
      true

  callback() for callback in callbacks

window.pagePixelPositionForPoint = (editorView, point) ->
  point = Point.fromObject point
  top = editorView.renderedLines.offset().top + point.row * editorView.lineHeight
  left = editorView.renderedLines.offset().left + point.column * editorView.charWidth - editorView.renderedLines.scrollLeft()
  { top, left }

window.tokensText = (tokens) ->
  _.pluck(tokens, 'value').join('')

window.setEditorWidthInChars = (editorView, widthInChars, charWidth=editorView.charWidth) ->
  editorView.width(charWidth * widthInChars + editorView.gutter.outerWidth())
  $(window).trigger 'resize' # update width of editor view's on-screen lines

window.setEditorHeightInLines = (editorView, heightInChars, charHeight=editorView.lineHeight) ->
  editorView.height(charHeight * heightInChars + editorView.renderedLines.position().top)
  $(window).trigger 'resize' # update editor view's on-screen lines

$.fn.resultOfTrigger = (type) ->
  event = $.Event(type)
  this.trigger(event)
  event.result

$.fn.enableKeymap = ->
  @on 'keydown', (e) => atom.keymap.handleKeyEvent(e)

$.fn.attachToDom = ->
  @appendTo($('#jasmine-content'))

$.fn.simulateDomAttachment = ->
  $('<html>').append(this)

$.fn.textInput = (data) ->
  this.each ->
    event = document.createEvent('TextEvent')
    event.initTextEvent('textInput', true, true, window, data)
    event = $.event.fix(event)
    $(this).trigger(event)
