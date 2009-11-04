module Skates

  ##
  # ClientConnection is in charge of the XMPP connection for a Regular XMPP Client.
  # So far, SASL Plain authenticationonly is supported
  # Upon stanza reception, and depending on the status (connected... etc), this component will handle or forward the stanzas.
  class ClientConnection < XmppConnection

    attr_reader :binding_iq_id, :session_iq_id

    ##
    # Creates a new ClientConnection and waits for data in the stream
    def initialize(params)
      super(params)
      @state = :wait_for_stream
    end

    ##
    # Connects the ClientConnection based on SRV records for the jid's domain, if no host has been provided.
    # It will not resolve if params["host"] is an IP.
    # And it will always use 
    def self.connect(params, handler = nil)
      host = params["host"] ? params["host"] : params["jid"].split("/").first.split("@").last 
      if host =~ /\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b/ 
        params["host"] = host
        params["port"] = params["port"] ? params["port"].to_i : 5222 
        super(params, handler)
      else
        resolve(host) do |ip, port|
          begin
            params["host"] = ip
            params["port"] = port
            super(params, handler)
            true # connected! Yay!
          rescue NotConnected
            # It will try the next pair of ip/port
            false
          end
        end
      end
    end

    ##
    # Builds the stream stanza for this client
    def stream_stanza
      doc = Nokogiri::XML::Document.new
      stream = Nokogiri::XML::Node.new("stream:stream", doc)
      doc.add_child(stream)
      stream["xmlns"] = stream_namespace
      stream["xmlns:stream"] = "http://etherx.jabber.org/streams"
      stream["to"] = jid.split("/").first.split("@").last
      stream["version"] = "1.0"
      paste_content_here = Nokogiri::XML::Node.new("paste_content_here", doc)
      stream.add_child(paste_content_here)
      doc.to_xml.split('<paste_content_here/>').first
    end

    ##
    # Connection_completed is called when the connection (socket) has been established and is in charge of "building" the XML stream 
    # to establish the XMPP connection itself.
    # We use a "tweak" here to send only the starting tag of stream:stream
    def connection_completed
      super
      send_xml(stream_stanza)
    end

    ##
    # Called upon stanza reception
    # Marked as connected when the client has been SASLed, authenticated, biund to a resource and when the session has been created
    def receive_stanza(stanza)
        case @state
        when :connected
          super # Can be dispatched

        when :wait_for_stream_authenticated
          if stanza.name == "stream:stream" && stanza.attributes['id']
            @state = :wait_for_bind
          end

        when :wait_for_stream
          if stanza.name == "stream:stream" && stanza.attributes['id']
            @state = :wait_for_auth_mechanisms
          end

        when :wait_for_auth_mechanisms
          if stanza.name == "stream:features"
            if stanza.at("starttls") # we shall start tls
              doc = Nokogiri::XML::Document.new
              starttls = Nokogiri::XML::Node.new("starttls", doc)
              doc.add_child(starttls)
              starttls["xmlns"] = "urn:ietf:params:xml:ns:xmpp-tls"
              send_xml(starttls.to_s)
              @state = :wait_for_proceed
            elsif stanza.at("mechanisms") # tls is ok
              if stanza.at("mechanisms").children.map() { |m| m.text }.include? "PLAIN"
                doc = Nokogiri::XML::Document.new
                auth = Nokogiri::XML::Node.new("auth", doc)
                doc.add_child(auth)
                auth['mechanism'] = "PLAIN"
                auth["xmlns"] = "urn:ietf:params:xml:ns:xmpp-sasl"
                auth.content = Base64::encode64([jid, jid.split("@").first, @password].join("\000")).gsub(/\s/, '')
                send_xml(auth.to_s)
                @state = :wait_for_success
              end
            end
          end

        when :wait_for_success
          if stanza.name == "success" # Yay! Success
            @state = :wait_for_stream_authenticated
            @parser.reset
            send_xml(stream_stanza)
          elsif stanza.name == "failure"
            if stanza.at("bad-auth") || stanza.at("not-authorized")
              raise AuthenticationError
            else
            end
          else
            # Hum Failure...
          end

        when :wait_for_bind
          if stanza.name == "stream:features"
            if stanza.at("bind")
              doc = Nokogiri::XML::Document.new
              # Let's build the binding_iq
              @binding_iq_id = Integer(rand(10000000))
              iq = Nokogiri::XML::Node.new("iq", doc)
              doc.add_child(iq)
              iq["type"] = "set"
              iq["id"] = binding_iq_id.to_s
              bind = Nokogiri::XML::Node.new("bind", doc)
              bind["xmlns"] = "urn:ietf:params:xml:ns:xmpp-bind"
              iq.add_child(bind)
              resource = Nokogiri::XML::Node.new("resource", doc)
              if jid.split("/").size == 2 
                resource.content = (@jid.split("/").last)
              else
                resource.content = "skates_client_#{binding_iq_id}"
              end
              bind.add_child(resource)
              send_xml(iq.to_s)
              @state = :wait_for_confirmed_binding
            end
          end

        when :wait_for_confirmed_binding
          if stanza.name == "iq" && stanza["type"] == "result" && Integer(stanza["id"]) ==  binding_iq_id
            if stanza.at("jid")
              @jid = stanza.at("jid").text
            end
            # And now, we must initiate the session
            @session_iq_id = Integer(rand(10000))
            doc = Nokogiri::XML::Document.new
            iq = Nokogiri::XML::Node.new("iq", doc)
            doc.add_child(iq)
            iq["type"] = "set"
            iq["id"] = session_iq_id.to_s
            session = Nokogiri::XML::Node.new("session", doc)
            session["xmlns"] = "urn:ietf:params:xml:ns:xmpp-session"
            iq.add_child(session)
            send_xml(iq.to_s)
            @state = :wait_for_confirmed_session
          end

        when :wait_for_confirmed_session
          if stanza.name == "iq" && stanza["type"] == "result" && Integer(stanza["id"]) == session_iq_id
            # And now, send a presence!
            doc = Nokogiri::XML::Document.new
            presence = Nokogiri::XML::Node.new("presence", doc)
            send_xml(presence.to_s)
            begin
              @handler.on_connected(self) if @handler and @handler.respond_to?("on_connected")
            rescue
              Skates.logger.error {
                "on_connected failed : #{$!}\n#{$!.backtrace.join("\n")}"
              }
            end
            @state = :connected
          end

        when :wait_for_proceed
          start_tls() # starting TLS
          @state = :wait_for_stream
          @parser.reset
          send_xml stream_stanza
        end
    end

    ##
    # Namespace of the client
    def stream_namespace
      "jabber:client"
    end

  end
end
