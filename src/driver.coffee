async = require 'async'
Bacon = require 'baconjs'
carrier = require 'carrier'
net = require 'net'
_ = require 'lodash'
lifx = require 'lifx'

houmioBridge = process.env.HOUMIO_BRIDGE || "localhost:3001"
bridgeSocket = new net.Socket()
lx = lifx.init()

console.log "Using HOUMIO_BRIDGE=#{houmioBridge}"

exit = (msg) ->
  console.log msg
  lx.close()
  process.exit 1

findBulb = (addressOrName) ->
  bulb = lx.bulbs[addressOrName]
  bulb ?= _.find lx.bulbs, (b) -> b.name == addressOrName

hueToKelvin = (hue) ->
  if(hue <= 170)
    2500 + Math.floor (hue * 6500 / 170)
  else
    9000 - Math.floor ((hue - 170) / 85 * 6500)

sendToLifx = (writeMessage) ->
  bulb = findBulb writeMessage.data.protocolAddress
  if bulb?
    powerOff = writeMessage.data.bri == 0
    params =
      stream: 0
      hue: Math.floor (writeMessage.data.hue / 0xff) * 0xffff
      saturation: Math.floor (writeMessage.data.saturation / 0xff) * 0xffff
      brightness: Math.floor (writeMessage.data.bri / 0xff) * 0xffff
      kelvin: hueToKelvin writeMessage.data.hue
      fadeTime:500
      protocol: 0x1400
    message = lifx.packet.setLightColour params
    try
      if powerOff
        lx.lightsOff bulb
      else
        lx.lightsOn bulb
      lx.sendToOne message, bulb
    catch error
      console.log "ERROR", error
  else
    console.log "ERROR", "Bulb not found", writeMessage.data.protocolAddress

toLines = (socket) ->
  Bacon.fromBinder (sink) ->
    carrier.carry socket, sink
    socket.on "close", -> sink new Bacon.End()
    socket.on "error", (err) -> sink new Bacon.Error(err)
    ( -> )

isWriteMessage = (message) -> message.command is "write"

openBridgeMessageStream = (socket) -> (cb) ->
  socket.connect houmioBridge.split(":")[1], houmioBridge.split(":")[0], ->
    lineStream = toLines socket
    messageStream = lineStream.map JSON.parse
    cb null, messageStream

bridgeMessagesToLifx = (bridgeStream) ->
  bridgeStream
    .filter isWriteMessage
    .throttle 25
    .onValue (message) ->
      console.log "Received message from bridge:", JSON.stringify message
      sendToLifx message

openStreams = [ openBridgeMessageStream(bridgeSocket) ]

async.series openStreams, (err, [bridgeStream]) ->
  if err then exit err
  bridgeStream.onEnd -> exit "Bridge stream ended"
  bridgeStream.onError (err) -> exit "Error from bridge stream:", err
  bridgeMessagesToLifx bridgeStream
  bridgeSocket.write (JSON.stringify { command: "driverReady", protocol: "lifx"}) + "\n"
