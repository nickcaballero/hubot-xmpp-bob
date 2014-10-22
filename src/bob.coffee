meld = require 'meld'
request = require 'request'
crypto = require 'crypto'
ltx = require 'ltx'
sharp = require 'sharp'

module.exports = (robot) ->
  url = /^(http|https):\/\/.+\/.*(png|jpg|jpeg|gif)$/
  cids = {}
  
  # Little content handler class
  class Content
    constructor: (@cid, @image) ->
      @hooks = []
      @loading = false
      @data = null
      
    handle: (data, contentType) =>
      @data = data
      @contentType = contentType
      @flush()
      
    register: (callback) =>
      @hooks.push callback
      if not @loading and @data
        @flush()
        
    flush: =>
      for callback in @hooks
        callback @data, @contentType
  
  applyAspects = ->
    
    # Wrap the send method of the client
    robot.adapter.client.send = meld.around robot.adapter.client.send, (jp) ->
      message = jp.args[0]
      
      # Check if this message is eligible for inline image
      if message.name is 'body'
        message = message.parent
        image = message.children[0].text()
        if image.match url
          
          # Calculate cid and allocate content handler
          shasum = crypto.createHash 'sha1'
          shasum.update image
          cid = 'sha1+' + shasum.digest('hex') + '@bob.xmpp.org';
          !cids[cid] && cids[cid] = new Content cid, image
          
          # Build message HTML content
          html = message.c 'html',
            xmlns: 'http://jabber.org/protocol/xhtml-im'
          body = html.c 'body',
            xmlns: 'http://www.w3.org/1999/xhtml'
          p = body.c 'p'
          p.c('img', {src: 'cid:' + cid})
          p.c('br')
          p.t(image)
            
      return jp.proceed()
    
    # Wrap the iq stanza handler of the adapter
    robot.adapter.readIq = meld.around robot.adapter.readIq, (jp) ->
      jp.proceed()
      
      # Check if this iq message is a request for data we know
      stanza = jp.args[0]
      if stanza.attrs.type is 'get' and stanza.children[0].name is 'data'
        data = stanza.children[0]
        if data.attrs.xmlns is 'urn:xmpp:bob'
          content = cids[data.attrs.cid]
          if content
            console.log 'Getting CID:', stanza.attrs.from, data.attrs.cid, content.image
            
            # Register with content handler for the data reply
            content.register (data, contentType) ->
              iq = new ltx.Element('iq',
                type: 'result'
                to: stanza.attrs.from
                id: stanza.attrs.id
              ).c('data',
                xmlns: 'urn:xmpp:bob'
                cid: content.cid
                type: contentType
              ).t(data)
              
              console.log 'Sending CID data:', content.cid, contentType, stanza.attrs.from
              sent = robot.adapter.client.send iq
            
            # If not loading yet, load content and inform the the content handler  
            if not content.loading
              content.loading = true
              request content.image, {encoding: null}, (error, response, body) ->
                if not error and response.statusCode is 200
                  console.log 'Received data for CID:', content.cid
                  contentType = response.headers['content-type']
                  
                  # sharp can't resize gifs, so move on
                  if contentType is 'image/gif'
                    content.handle body.toString('base64'), contentType
                    
                    # Resize the image. This ensures that we fall within the size limits
                  else
                    sharp(body).resize(200).quality(80).toBuffer().then (buffer) ->
                      content.handle buffer.toString('base64'), contentType
                    
  # Handle reconnections
  robot.adapter.makeClient = meld.around robot.adapter.makeClient, (jp) ->
    jp.proceed()
    applyAspects()
  
  # Initialize
  applyAspects()
