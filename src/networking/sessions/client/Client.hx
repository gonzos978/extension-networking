package networking.sessions.client;

import cpp.vm.Mutex;
import cpp.vm.Thread;
import networking.utils.NetworkEvent;

import networking.server.*;
import networking.sessions.Session;
import networking.sessions.items.ClientObject;
import networking.sessions.server.Server;
import networking.sessions.server.Server.PortType;
import networking.utils.*;


/**
 * Client wrapper. Represents a client session.
 *
 * Instances from this class shouldn't be handled manually, but with Session instances.
 *
 * @author Daniel Herzog
 */
class Client {
  /** Default IP to connect into. Used in the constructor. **/
  public static inline var DEFAULT_IP: String = '127.0.0.1';

  /** Default port to connect into. Used in the constructor. **/
  public static inline var DEFAULT_PORT: PortType = 9696;

  /** Default session identifier (random). Used in the constructor. **/
  public static inline var DEFAULT_UUID: String = null;

  /** ClientObject info. Contains low level objects (sockets). **/
  public var info(default, null): ClientObject;

  /** Current server's ip. **/
  public var ip(default, null): String;

  /** Current server port. **/
  public var port(default, null): PortType;

  private var _session: Session;
  private var _mutex: Mutex;
  private var _uuid: Uuid;
  private var _thread: Thread;
  private var _thread_active: Bool = true;

  /**
   * Create a new client session that tries connects to the given server. This constructor shouldn't be called manually.
   *
   * @param session Reference to session object.
   * @param uuid Session uuid. Random by default.
   * @param ip Server ip to connect into.
   * @param port Server port to connect into.
   */
  public function new(session: Session, uuid: Uuid = DEFAULT_UUID, ip: String = DEFAULT_IP, port: PortType = DEFAULT_PORT) {
    this._session = session;
    this.ip = ip;
    this.port = port;

    _uuid = uuid;
    _thread_active = true;
    _thread = Thread.create(threadListen);
    _mutex = new Mutex();
  }

  /**
   * Send an object to the server.
   *
   * @param obj Object to send to the server.
   */
  public function send(obj: Dynamic) {
    try {
      if (!info.send(obj))
        throw 'Could not send message to server.';
    }
    catch (z: Dynamic) {
      var server: Server = info != null ? info.server : null;
      _session.triggerEvent(NetworkEvent.MESSAGE_SENT_FAILED, { server: server, client: info, message: obj } );
    }
  }

  /**
   * Stop the client session, to disconnect from the server.
   */
  public function stop() {
    _thread_active = false;
    disconnect();
    _session.triggerEvent(NetworkEvent.CLOSED, { client: this, message: 'Session closed.' } );
  }


  /**
   * Server IP direction.
   *
   * @return IP direction (string).
   */
  public function serverIp(): String {
    return info.socket.peer().host.toString();
  }

  /**
   * Server port.
   *
   * @return Current port (PortType).
   */
  public function serverPort(): PortType {
    return info.socket.peer().port;
  }


  // Listener thread
  private function threadListen() {
    // To avoid lagging the main thread, the initialization code is moved right here.
    // If this generates some errors, move it to the new method.
    try {
      info = new ClientObject(_session, _uuid, null);
      info.initializeSocket(ip, port);

      _session.triggerEvent(NetworkEvent.INIT_SUCCESS, { message: 'Connected to $ip:$port' } );
      _session.triggerEvent(NetworkEvent.CONNECTED, { message: 'Connected to $ip:$port' });
    }
    catch(e: Dynamic) {
      _session.triggerEvent(NetworkEvent.INIT_FAILURE, { message: 'Could not connect to $ip:$port: $e' });
      return;
    }

    info.load();
    if (!info.send({ verb: '_core.sync.update_client_data', uuid: info.uuid })) {
      _session.triggerEvent(NetworkEvent.INIT_FAILURE, { message: "Could not update client's data" });
      return;
    }

    var disconnect_message: String = 'Disconnected';

    while (true) {
      _mutex.acquire();
      if (!_thread_active) break;
      _mutex.release();

      try {
        info.read();
      }
      catch (z: Dynamic) {
        disconnect_message = 'Connection lost: ${z}';
        break;
      }
    }
    _mutex.release();

    disconnect();
    _session.triggerEvent(NetworkEvent.DISCONNECTED, { message: disconnect_message });
  }

  private function disconnect() {
    _mutex.acquire();
    try {
      info.destroySocket();
      _thread_active = false;
    }
    catch (e:Dynamic) {
      throw e;
    }
    _mutex.release();
  }
}