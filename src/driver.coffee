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

findGateway = (bulb) ->
  _.find lx.gateways, (g) -> g.bulbAddress == bulb.addr.toString "hex"

sendCommand = (command, gw, bulb) ->
	bulb.addr.copy(command, 8)
	gw.site.copy(command, 16);
	lx._sendPacket(gw.ip, gw.port, command);

hueToKelvin = (hue) ->
  if(hue <= 170)
    2500 + Math.floor (hue * 6500 / 170)
  else
    9000 - Math.floor ((hue - 170) / 85 * 6500)

sendToLifx = (writeMessage) ->
  bulb = findBulb writeMessage.data.protocolAddress
  if bulb?
    gw = findGateway bulb
    if gw?
      powerParams =
        onoff: if writeMessage.data.bri == 0 then 0 else 0xff
        protocol: 0x1400
      powerMessage = packet.setPowerState powerParams
      colorParams =
        stream: 0
        hue: Math.floor (writeMessage.data.hue / 0xff) * 0xffff
        saturation: Math.floor (writeMessage.data.saturation / 0xff) * 0xffff
        brightness: Math.floor (writeMessage.data.bri / 0xff) * 0xffff
        kelvin: hueToKelvin writeMessage.data.hue
        fadeTime:500
        protocol: 0x1400
      colorMessage = lifx.packet.setLightColour colorParams
      try
        sendCommand powerMessage, gw, bulb
        sendCommand colorMessage, gw, bulb
      catch error
        console.log "ERROR", error
    else
      console.log "ERROR", "Gateway not found", bulb.addr.toString "hex"
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
