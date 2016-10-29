package networking.sessions.server;

import networking.utils.NetworkEvent;
import networking.utils.NetworkLogger;

import networking.sessions.Session;
import networking.sessions.items.ClientObject;
import networking.sessions.items.ServerObject;
import networking.utils.*;

import sys.net.Socket;

#if neko
import neko.vm.Thread;
import neko.vm.Mutex;
#elseif cpp
import cpp.vm.Mutex;
import cpp.vm.Thread;
#end

/** Port type (integer). **/
typedef PortType = Int;

/** Clients list (array of ClientObjects). **/
typedef Clients = Array<ClientObject>;

/**
 * Server wrapper. Represents a server session.
 *
 * Instances from this class shouldn't be handled manually, but with Session instances.
 *
 * @author Daniel Herzog
 */
class Server {
  /** Default IP host to bind into. Used in the constructor. **/
  public static inline var DEFAULT_IP: String = '127.0.0.1';

  /** Default port to bind into. Used in the constructor. **/
  public static inline var DEFAULT_PORT: PortType = 9696;

  /** Max allowed clients connected to the server. Used in the constructor. **/
  public static inline var DEFAULT_MAX_CONNECTIONS: Int = 24;

  /** Default session identifier (random). Used in the constructor. **/
  public static inline var DEFAULT_UUID: String = null;

  /** Max allowed connection pending requests. This value is hard-coded and should not be modified. **/
  public static inline var MAX_LISTEN_INCOMING_REQUESTS: Int = 200;

  /** Clients connected to the current server. **/
	public var clients: Clients;

  /** Low level information. **/
	public var info: ServerObject;

  /** Server binded ip. **/
  public var ip(default, null): String;

  /** Current server port. **/
  public var port(default, null): PortType;

  /** Max allowed clients. **/
  public var max_connections(default, null): Int;

  private var _session: Session;
  private var _mutex: Mutex;
  private var _uuid: Uuid;
  private var _thread: Thread;
  private var _thread_active: Bool = true;

  /**
   * Create a new server session that will bind the given ip and port.
   * This constructor shouldn't be called manually.
   *
   * @param session Reference to session object.
   * @param uuid Session uuid. Random by default.
   * @param ip Server ip to connect into.
   * @param port Server port to connect into.
   * @param max_connections Max allowed clients at the same time.
   */
	public function new(session: Session, uuid: Uuid = DEFAULT_UUID, ip: String = DEFAULT_IP, port: Null<PortType> = DEFAULT_PORT, max_connections: Null<Int> = DEFAULT_MAX_CONNECTIONS) {
    _session = session;
    _mutex = new Mutex();
    _uuid = uuid;

		try {
      info = new ServerObject(_session, _uuid, this);
      info.initializeSocket(ip, port);
		}
    catch (e: Dynamic) {
      _session.triggerEvent(NetworkEvent.INIT_FAILURE, { server: this, message: 'Could not bind to $ip:$port. Ensure that no server is running on that port. Reason: $e' } );
			return;
		}

    _session.triggerEvent(NetworkEvent.INIT_SUCCESS, { server: this, message: 'Binded to $ip:$port.' });

    this.ip = ip;
    this.port = port;
    this.max_connections = max_connections;

		clients = [];
    _thread_active = true;
		_thread = Thread.create(threadAccept);
	}

	/**
	 * Sends given object to all active clients, also known as broadcasting.
   * To send messages to a single client, use something like `clients[0].send(...)`.
   *
	 * @param obj Message to broadcast.
	 */
	public function broadcast(obj: Dynamic) {
    try {
      for (cl in clients) {
        if (!cl.send(obj)) disconnectClient(cl, false);
      }
      _session.triggerEvent(NetworkEvent.MESSAGE_BROADCAST, { server: this, message: obj });
    }
    catch (e: Dynamic) {
      _session.triggerEvent(NetworkEvent.MESSAGE_BROADCAST_FAILED, { server: this, message: obj });
    }
	}

  /**
   * Disconnect a given client from the server. This method should not be called manually, but withing Session instances.
   *
   * @param cl Client to disconnect from the server.
   * @param dispatch Trigger a DISCONNECT event.
   * @return Returns true if the client is disconnected successfully, false otherwise.
   */
  public function disconnectClient(cl: ClientObject, dispatch: Bool = true): Bool {
    try {
      if(!cl.active) return false;

      if(dispatch) {
        _session.triggerEvent(NetworkEvent.DISCONNECTED, { server: this, client: cl } );
      }

      cl.destroySocket();
      clients.remove(cl);
    }
    catch (e:Dynamic) { }
    return true;
  }

  /**
   * Disconnect all clients, and close the current session.
   */
  public function stop() {
    _mutex.acquire();
    _thread_active = false;
    cleanup();
    _mutex.release();
    _session.triggerEvent(NetworkEvent.CLOSED, { server: this, message: 'Session closed.' } );
  }

  /**
   * An alias for `broadcast`.
   * @param obj Message to broadcast.
   */
  public inline function send(obj: Dynamic) {
    broadcast(obj);
  }

	// Accepts new sockets and spawns new threads for them.
	private function threadAccept() {
		while (true) {
      _mutex.acquire();
      if (!_thread_active) break;
      _mutex.release();

      var sk: Socket = null;
      try {
        sk = info.socket.accept();
      }
      catch(e: Dynamic) {
        NetworkLogger.error(e);
      }
			if (sk != null) {
        var cl = new ClientObject(_session, null, this, sk);

        if (!maxClientsReached()) {
				  Thread.create(getThreadListen(cl));
        }
        else {
          var message = { verb: '_core.errors.server_full', message: 'Server is full.' };
          cl.send(message);
          _session.triggerEvent(NetworkEvent.SERVER_FULL, { client: cl, message: message });
        }
			}
		}
    _mutex.release();
	}

  // Destroy the current session.
  private function cleanup() {
    if (clients == null) return;

    for (cl in clients) {
      disconnectClient(cl, false);
    }

    info.destroySocket();
    clients = [];
  }

  // Check if the server is full.
  private function maxClientsReached(): Bool {
    return clients.length >= max_connections;
  }

	// Creates a new thread function to handle given ClientInfo.
	private function getThreadListen(cl: ClientObject) {
		return function() {
			clients.push(cl);
      cl.load();

      _session.triggerEvent(NetworkEvent.CONNECTED, { server: this, client: cl } );

			while (cl.active) {
				try {
					cl.read();
				}
        catch(z: Dynamic) {
					break;
				}
			}

      disconnectClient(cl);
		}
	}
}