PNGDecoder = require 'png-stream/decoder'
PNGEncoder = require 'png-stream/encoder'
stream = require 'stream'
    
class PNGImage

  COMPONENTS =
    rgb: 3
    rgba: 4
    gray: 1
    graya: 2
    indexed: 1

  constructor: (@source, @label) ->
    # Read the image dimensions synchronously, and put the chunk back on the stream
    chunk = @source.read(24)
    @source.unshift chunk
    
    @width = chunk.readUInt32BE(16)
    @height = chunk.readUInt32BE(20)
    
    @obj = null

  embed: (document) ->
    decoder = new PNGDecoder
      indexed: true
    
    @obj = document.ref
      Type: 'XObject'
      Subtype: 'Image'

    decoder.once 'format', (format) =>
      @obj.data.BitsPerComponent = decoder.bits
      @width = @obj.data.Width = format.width
      @height = @obj.data.Height = format.height
      @obj.data.ColorSpace = switch format.colorSpace
        when 'rgb', 'rgba' then 'DeviceRGB'
        when 'gray', 'graya' then 'DeviceGray'
        when 'indexed'
          palette = document.ref()
          palette.end format.palette
          ['Indexed', 'DeviceRGB', (format.palette.length / 3) - 1, palette]

      colors = COMPONENTS[format.colorSpace]
      @obj.data.DecodeParms =
        Predictor: 15
        Colors: colors
        BitsPerComponent: decoder.bits
        Columns: format.width
        
      # Add an SMask for images with an alpha channel
      if format.colorSpace in ['rgba', 'graya'] or format.alphaPalette
        sMask = document.ref
          Type: 'XObject'
          Subtype: 'Image'
          Height: format.height
          Width: format.width
          BitsPerComponent: 8
          ColorSpace: 'DeviceGray'
          DecodeParms:
            Predictor: 15
            Colors: 1
            BitsPerComponent: 8
            Columns: format.width

        @obj.data.SMask = sMask
      
      # Normal non-indexed images with alpha need to be split
      if format.colorSpace in ['rgba', 'graya']
        @obj.data.DecodeParms.Colors--
            
        split = new SplitAlphaStream colors
        split.alpha
          .pipe new FilterStream 1, format.width
          .pipe sMask

        split.image
          .pipe new FilterStream colors - 1, format.width
          .pipe @obj
          
        decoder.pipe split
      
      # Indexed images with alpha need to generate an SMask image from the palette
      else if format.alphaPalette
        decoder
          .pipe new PaletteStream format.alphaPalette
          .pipe new FilterStream 1, format.width
          .pipe sMask
          
        decoder
          .pipe new FilterStream colors, format.width
          .pipe @obj
          
      # Other images can be embedded directly, without decoding.
      else
        decoder._decodeRaw = true
        @obj.compress = no
        @obj.data.Filter = 'FlateDecode'

        decoder.pipe @obj
    
    @source.pipe decoder

# This stream filters pixel data using the PNGEncoder
class FilterStream extends stream.Transform
  constructor: (colors, width) ->
    super()
    @_prevScanline = null
    @_pixelBytes = (8 * colors) >> 3
  
  _transform: (data, encoding, callback) ->
    callback null, PNGEncoder::_filter.call this, data
    
# This stream separates the alpha channel and other channels into two streams
class SplitAlphaStream extends stream.Writable
  constructor: (@components) ->
    super()
    @image = new stream.PassThrough
    @alpha = new stream.PassThrough
    
  _write: (data, encoding, callback) ->
    len = data.length / @components | 0
    rgb = new Buffer len * (@components - 1)
    alpha = new Buffer len
    i = rgbIndex = alphaIndex = 0
    
    while i < data.length
      for j in [0...@components - 1]
        rgb[rgbIndex++] = data[i++]

      alpha[alphaIndex++] = data[i++]
      
    @image.write rgb
    @alpha.write alpha
    
    callback()
    
  end: (chunk) ->
    super
    @image.end()
    @alpha.end()
    
# This stream converts indexed transparency data to actual pixels
class PaletteStream extends stream.Transform
  constructor: (@palette) ->
    super()
    
  _transform: (data, encoding, callback) ->
    res = new Buffer data.length
    for index, i in data
      res[i] = @palette[index]
      
    callback null, res
    
module.exports = PNGImage