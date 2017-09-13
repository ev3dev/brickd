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
    Binding? system_battery_state_binding;
    Binding? system_battery_voltage_binding;

    /**
     * Gets the state of the system battery or BatteryState.OK if there is no
     * battery.
     */
    public BatteryState system_battery_state { get; internal set; }

    /**
     * Gets the system battery voltage in mV or 0 if there is no battery.
     */
    public int system_battery_voltage { get; internal set; }

    public PowerMonitor () {
        Object ();
        supplies = new HashTable<string, Supply> (str_hash, str_equal);
        client = new Client ({ "power_supply" });
        client.uevent.connect (handle_uevent);
        var list = client.query_by_subsystem ("power_supply");
        list.foreach (device => handle_uevent ("add", device));
    }

    void handle_uevent (string action, Device device) {
        var name = device.get_name ();
        switch (action) {
        case "add":
            debug ("adding %s", name);
            var supply = new Supply (device);
            supplies[name] = supply;
            if (supply.scope == "System" && supply.type_ == "Battery") {
                debug ("is system battery");
                system_battery_state_binding = supply.bind_property ("battery-state",
                    this, "system-battery-state", BindingFlags.SYNC_CREATE);
                system_battery_voltage_binding = supply.bind_property ("voltage",
                    this, "system-battery-voltage", BindingFlags.SYNC_CREATE);
            }
            break;
        case "remove":
            debug ("removing %s", name);
            if (system_battery_state_binding != null) {
                var system_battery = (Supply)system_battery_state_binding.target;
                if (system_battery.device.get_name () == name) {
                    system_battery_state_binding.unbind ();
                    system_battery_state_binding = null;
                    system_battery_state = BatteryState.OK;
                    system_battery_voltage_binding.unbind ();
                    system_battery_voltage_binding = null;
                    system_battery_voltage = 0;
                }
            }
            
            supplies.remove (name);
            break;
        }
    }
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
            case "evb-battery":
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
            case "brickpi-battery":
            case "brickpi3-battery":
                full_voltage = 10000;
                empty_voltage = 8500;
                low_warn_voltage = 8000;
                low_shutdown_voltage = 7000;
                break;
            case "pistorms-battery":
                full_voltage = 8100;
                empty_voltage = 6500;
                low_warn_voltage = 6000;
                low_shutdown_voltage = 5000;
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

    /**
     * Poll the system battery for changes.
     */
    bool handle_timeout () {
        // have to change at least 0.01V before updating the voltage property
        var new_voltage = _get_voltage ();
        if ((voltage - new_voltage).abs () >= 10) {
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
