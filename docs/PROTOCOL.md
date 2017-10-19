brickd Communication Protocol
=============================

This document describes the `brickd` communication protocol.


Connection
----------

`brickd` listens for incoming TCP connections on the `localhost` interface on
port `31313` (IPv4 and IPv6).


Protocol
--------

The protocol uses ASCII text encoding. Messages generally have the format:

    type [ " " data ] "\n"

The specification is given in upper-case, but the server is case-insensitive.

### Sequence

The server initiates the connection with...

    "BRICKD" " " "VERSION" " " major "." minor "." revision "\n"

...to which the client must reply...

    "YOU ARE A ROBOT" "\n"

The server responds with...

    "OK" "\n"

At this point, the server may send unsolicited `MSG` messages and the client is
free to send any commands.

To terminate the connection, send `BYE`.

### Message Types

The server has two types of messages. Broadcast messages, which begin with `MSG`
and responses, which begin with `OK` or `BAD`.

`MSG` contains a message type followed by optional data that is defined by the
type given.

    "MSG" " " msg-type [ " " msg-data ] "\n"

The special message types of `INFO`, `WARN` and `CRITICAL` contain messages
that should be shown to the user.

    "MSG" " " ("INFO" / "WARN" / "CRITICAL") " " message "\n"

`PROPERTY` messages contain key/value pairs.

    "MSG" " " "PROPERTY" " " key " " value "\n"

Responses can have an optional message.

    ( "OK" / "BAD" ) [ " " message ] "\n"

`OK` indicates that the previous command completed successfully. `BAD` indicates
that the previous command was incorrectly formatted or contained illegal
arguments.

Client commands begin with a command name followed by any arguments required
by that command. Actual command names are given in the next section.

    cmd [ " " args ] "\n"


### Commands

The `brickd` server responds to the following commands:

**BYE**

Closes the network connection. Server responds with `OK` before ending the
connection.

    "BYE" "\n"

**GET** (since 1.1.0)

Requests a property value. Valid keys are listed in the *Properties* section
below.

    "GET" " " key "\n"

The response will `BAD` if an invalid key is requested. Otherwise, it will
return `OK` along with the value.

    "OK" " " value "\n"

**WATCH**

Subscribes to additional `MSG` notifications.

    "WATCH" subsystem "\n"

Currently, the only subsystem is `POWER`. This will enable broadcast messages
for the `system.battery.voltage` property.


### Properties

`system.info.serial` (since 1.1.0) is the serial number of the device.

`system.battery.voltage` is the current battery voltage in millivolts.
