## 0.2.1

- onConnect, onDisconnect, onError, onHeartbeatTimeout and onUpdate methods setted as Streams
- NesError constructor prints the error instead throw it

## 0.2.0

- nes_client_base.dart exports client.dart
- Client changed name to NesClient
- Fix connect method auth field
- retries, delay and maxDelay values setted as milliseconds
- Fix reauthenticate method to return a Future and get as parameter a Map
- All the classes' method toMap return only the not null values

## 0.1.1

- Set connect function as a Future
- nextTick setted as private
- id attribute changed to String
- _connect waits until the innerWebSocket it's open
- _connect returns the _ws.stream listen function
- _onMessage handler on a switch
- _Message toString method returns the data attribute

## 0.1.0

- Using the web_socket_channel package again

## 0.0.3

- Copied all the functions as they are in the Javascript client

## 0.0.1

- Initial version.
