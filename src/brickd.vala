/*
 * brickd.vala
 *
 * Copyright (c) 2017 David Lechner <david@lechnology.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

/*
 * This is the main entry point for brickd.
 */

class BrickApp : Application {
    PowerMonitor power_monitor;
    SocketListener listener;
    bool running;

    public BrickApp () {
        Object ();
        hold ();
        setup_signal_handlers ();
    }

    void setup_signal_handlers () {
        Unix.signal_add (Posix.SIGINT, () => {
            // chain up to SIGTERM handler to prevent double-release of app
            Posix.kill (Posix.getpid (), Posix.SIGTERM);
            return Source.REMOVE;
        });
        Unix.signal_add (Posix.SIGTERM, () => {
            release ();
            return Source.REMOVE;
        });
    }

    public override void activate () {
        try {
            running = true;
            power_monitor = new PowerMonitor ();
            power_monitor.notify["system-battery-state"].connect ((s, p) => {
                handle_system_battery_state ();
            });
            handle_system_battery_state ();

            // just listen on localhost to prevent remote meddling
            listener = new SocketListener ();
            var ipv4_addr = new InetSocketAddress (new InetAddress.loopback (SocketFamily.IPV4), 31313);
            var ipv6_addr = new InetSocketAddress (new InetAddress.loopback (SocketFamily.IPV6), 31313);
            SocketAddress effective;
            listener.add_address (ipv4_addr, SocketType.STREAM, SocketProtocol.TCP, null, out effective);
            listener.add_address (ipv6_addr, SocketType.STREAM, SocketProtocol.TCP, null, out effective);
            run_listener.begin ();
        }
        catch (Error err) {
            stderr.printf ("Failed to start: %s\n", err.message);
            Process.exit (1);
        }
    }

    public override void shutdown () {
        base.shutdown ();
        running = false;
        // close all client connections
        listener.close ();
    }

    /**
     * Global handler for system battery state changes.
     */
    void handle_system_battery_state () {
        switch (power_monitor.system_battery_state) {
        case BatteryState.LOW:
            try {
                var wall = new Subprocess (SubprocessFlags.NONE, "/usr/bin/wall",
                    "Low battery. Power off or connect a charger soon.");
                wall.wait_async.begin ();
            }
            catch (Error err) {
                critical ("%s", err.message);
            }
            break;
        case BatteryState.CRITICAL:
            try {
                message ("Critical battery level. Powering off NOW!");
                var poweroff = new Subprocess (SubprocessFlags.NONE, "/sbin/poweroff");
                poweroff.wait_async.begin ();
            }
            catch (Error err) {
                critical ("%s", err.message);
            }
            break;
        }
    }

    /**
     * Loop for handling incoming network connections.
     */
    async void run_listener () {
        while (running) {
            try {
                var connection = yield listener.accept_async ();
                handle_connection.begin (connection);
            }
            catch (Error err) {
                debug ("Error accepting socket: %s", err.message);
            }
        }
    }

    /**
     * Helper function to simplify cal to OutputStream.write_async ().
     */
    static async void write_line_async (OutputStream stream, string msg) throws Error {
        var builder = new StringBuilder (msg);
        builder.append_c ('\n');
        yield stream.write_async (builder.data);
    }

    /**
     * Loop for handling a single network connection.
     */
    async void handle_connection (SocketConnection connection) throws Error {
        var in_stream = new DataInputStream (connection.input_stream);
        var out_stream = connection.output_stream;
        ulong system_battery_state_id = 0;
        ulong system_battery_voltage_id = 0;

        try {
            yield write_line_async (out_stream, "BRICKD VERSION %s".printf (BRICKD_VERSION));
            var reply = yield in_stream.read_line_async ();
            // I am not a robot...
            if (reply == null || reply.strip ().up () != "YOU ARE A ROBOT") {
                yield write_line_async (out_stream, "BAD You don't know the secret handshake");
            }
            else {
                yield write_line_async (out_stream, "OK");
                system_battery_state_id = power_monitor.notify["system-battery-state"].connect ((s, p) => {
                    handle_connection_system_battery_state.begin (out_stream);
                });
                yield handle_connection_system_battery_state (out_stream);

                while (running) {
                    reply = yield in_stream.read_line_async ();
                    if (reply == null) {
                        continue;
                    }
                    reply = reply.strip ();
                    if (reply.up () == "BYE") {
                        yield write_line_async (out_stream, "OK Until next time...");
                        break;
                    }
                    var parts = reply.split (" ", 2);
                    if (parts.length != 2) {
                        yield write_line_async (out_stream, "BAD Too short");
                        continue;
                    }
                    switch (parts[0].up ()) {
                    case "WATCH":
                        switch (parts[1].up ()) {
                        case "POWER":
                            if (system_battery_voltage_id != 0) {
                                yield write_line_async (out_stream, "OK Already watching POWER");
                                break;
                            }
                            yield write_line_async (out_stream, "OK");
                            
                            system_battery_voltage_id = power_monitor.notify["system-battery-voltage"].connect ((s, p) => {
                                handle_connection_system_battery_voltage.begin (out_stream);
                            });
                            yield handle_connection_system_battery_voltage (out_stream);

                            break;
                        default:
                            yield write_line_async (out_stream, "BAD Unknown WATCH target");
                            break;
                        }
                        break;
                    default:
                        yield write_line_async (out_stream, "BAD Unknown command");
                        break;
                    }
                }
            }
        }
        catch (Error err) {
            debug ("Connection error: %s", err.message);
        }

        if (system_battery_voltage_id != 0) {
            power_monitor.disconnect (system_battery_voltage_id);
        }
        if (system_battery_state_id != 0) {
            power_monitor.disconnect (system_battery_state_id);
        }
        connection.close ();
    }

    /**
     * Handler to emit system battery state messages to a client.
     */
    async void handle_connection_system_battery_state (OutputStream out_stream) throws Error {
        switch (power_monitor.system_battery_state) {
            case BatteryState.LOW:
                yield write_line_async (out_stream, "MSG WARN Battery is getting low");
                break;
            case BatteryState.CRITICAL:
                yield write_line_async (out_stream, "MSG CRITICAL System is shutting down due to low battery");
                break;
            }
    }

    /**
     * Handler to emit system battery voltage messages to a client.
     */
    async void handle_connection_system_battery_voltage (OutputStream out_stream) throws Error {
        yield write_line_async (out_stream,
            "MSG PROPERTY system.battery.voltage %d".printf (power_monitor.system_battery_voltage));
    }
}

public static int main (string[] args) {
    var app = new BrickApp ();
    return app.run (args);
}
