/*
 * power_monitor.vala
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

using GUdev;

/**
 * Describes the state of a battery.
 */
enum BatteryState {
    /**
     * Battery is OK.
     */
    OK,

    /**
     * Battery is getting low.
     */
    LOW,

    /**
     * Battery is dangerously low.
     */
    CRITICAL
}

/**
 * This class provides power monitoring capabilities.
 */
sealed class PowerMonitor: Object {
    Client client;
    HashTable<string, Supply> supplies;
    Supply? system_battery;
    ulong system_battery_signal_id;
    ulong uevent_id;

    public PowerMonitor () {
        Object ();
        supplies = new HashTable<string, Supply> (str_hash, str_equal);
        client = new Client ({ "power_supply" });
        uevent_id = client.uevent.connect (handle_uevent);
        var list = client.query_by_subsystem ("power_supply");
        list.foreach (device => handle_uevent ("add", device));
    }

    ~PowerMonitor () {
        client.disconnect (uevent_id);
        supplies.foreach ((key, val) => handle_uevent ("remove", val.device));
    }

    void handle_uevent (string action, Device device) {
        switch (action) {
        case "add":
            debug ("adding %s", device.get_name ());
            var supply = new Supply (device);
            if (supply.name == null) {
                critical ("Property \"name\" is null for device %s", device.get_name ());
                break;
            }
            supplies[supply.name] = supply;
            if (supply.scope == "System" && supply.type_ == "Battery") {
                debug ("is system battery");
                system_battery = supply;
                system_battery_signal_id = system_battery.notify["battery-state"].connect (handle_system_battery_state);
                Idle.add (() => {
                    system_battery.notify_property ("battery-state");
                    return Source.REMOVE;
                });
            }
            break;
        case "remove":
            debug ("removing %s", device.get_name ());
            var name = device.get_property ("POWER_SUPPLY_NAME");
            if (name == null) {
                break;
            }
            if (system_battery != null && system_battery.name == name) {
                system_battery.disconnect (system_battery_signal_id);
                system_battery = null;
            }
            supplies.remove (name);
            break;
        }
    }

    void handle_system_battery_state (Object source, ParamSpec pspec) {
        system_battery_event (system_battery.battery_state);
    }

    public signal void system_battery_event (BatteryState state);
}

sealed class Supply: Object {
    public Device device;
    uint timeout_id;
    int battery_state_debounce;

    public Supply (Device device) {
        Object ();
        this.device = device;
        if (type_ == "Battery") {
            // We may know more about the battery and the device it is running
            // on than the driver does, so if we recognize the name, use our
            // own values.
            switch (name) {
            case "lego-ev3-battery":
                // EV3 numbers are taken from the official LEGO source code
                switch (technology) {
                // TODO: handle case for NiMH
                case "Li-ion":
                    // LEGO rechargeable battery back
                    full_voltage = 7500;
                    empty_voltage = 7100;
                    low_warn_voltage = 6500;
                    low_shutdown_voltage = 6000;
                    break;
                default:
                    // Regular AA batteries
                    full_voltage = 7500;
                    empty_voltage = 6200;
                    low_warn_voltage = 5500;
                    low_shutdown_voltage = 4500;
                    break;
                }
                break;
            default:
                // full voltage is 85% of max design
                full_voltage = int.parse (device.get_property ("POWER_SUPPLY_VOLTAGE_MAX_DESIGN")) / 1000 * 85 / 100;
                // shutdown at min design
                low_shutdown_voltage = int.parse (device.get_property ("POWER_SUPPLY_VOLTAGE_MIN_DESIGN")) / 1000;
                // warn at 120% of min design
                low_warn_voltage = low_shutdown_voltage * 120 / 100;
                // empty at 130% min design
                empty_voltage = low_shutdown_voltage * 130 / 100;
                break;
            }
        }

        timeout_id = Timeout.add_seconds (1, handle_timeout);
        handle_timeout ();
    }

    ~Supply () {
        Source.remove (timeout_id);
    }
    
    /**
     * Get the type.
     */
    public string type_ {
        get {
            return device.get_sysfs_attr ("type");
        }
    }

    /**
     * Get the name.
     */
    public string? name {
        get {
            return device.get_property ("POWER_SUPPLY_NAME");
        }
    }

    /**
     * Get the scope.
     */
    public string? scope {
        get {
            return device.get_property ("POWER_SUPPLY_SCOPE");
        }
    }

    /**
     * Get the battery technology.
     */
    public string? technology {
        get {
            return device.get_property ("POWER_SUPPLY_TECHNOLOGY");
        }
    }

    /**
     * Get the current voltage in mV.
     */
    public int voltage { get; private set; }

    int _get_voltage () {
        try {
            var path = Path.build_filename (device.get_sysfs_path (), "voltage_now");
            string content;
            FileUtils.get_contents (path, out content);
            return int.parse (content) / 1000;
        }
        catch (Error err) {
            return 0;
        }
    }

    /**
     * Get the "full" voltage for batteries in mV.
     */
    public int full_voltage { get; private set; }

    /**
     * Get the "empty" voltage for batteries in mV.
     */
    public int empty_voltage { get; private set; }

    /**
     * Get the voltage that triggers a low battery warning in mV.
     */
    public int low_warn_voltage { get; private set; }

    /**
     * Get the voltage that triggers a system shutdown in mV.
     */
    public int low_shutdown_voltage { get; private set; }

    /**
     * Get the battery state.
     */
    public BatteryState battery_state { get; private set; }

    BatteryState _get_battery_state () {
        if (voltage < low_shutdown_voltage) {
            return BatteryState.CRITICAL;
        }
        if (voltage < low_warn_voltage) {
            return BatteryState.LOW;
        }
        return BatteryState.OK;
    }

    bool handle_timeout () {
        // poll the voltage
        var new_voltage = _get_voltage ();
        if (voltage != new_voltage) {
            voltage = new_voltage;
        }
        var new_state = _get_battery_state ();
        if (battery_state == new_state) {
            battery_state_debounce = 0;
        }
        else {
            battery_state_debounce++;
            if (battery_state_debounce >= 10) {
                battery_state_debounce = 0;
                battery_state = new_state;
            }
        }

        return Source.CONTINUE;
    }
}
