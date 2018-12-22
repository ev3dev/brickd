/*
 * power_monitor.vala
 *
 * Copyright (c) 2017-2018 David Lechner <david@lechnology.com>
 * Copyright (C) 2010-2013 The LEGO Group
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
    LOW_VOLT,

    /**
     * Battery is dangerously low.
     */
    CRITICAL_LOW_VOLT,

    /**
     * Battery temperature is getting too high.
     */
    HIGH_TEMP,

    /**
     * Battery temperature is dangerously high.
     */
    CRITICAL_HIGH_TEMP,

    /**
     * Battery is probably not connected.
     */
    NOT_PRESENT
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
    float high_temp_warn;
    float high_temp_shutdown;
    float temperature;
    bool monitor_temperature;

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
                    high_temp_warn = 40.0f;
                    high_temp_shutdown = 45.0f;
                    monitor_temperature = true;
                    break;
                }
                /* EVB show ~0.01V when powered from USB */
                not_present_voltage = 500;
                break;
            case "brickpi-battery":
            case "brickpi3-battery":
                full_voltage = 10000;
                empty_voltage = 8500;
                low_warn_voltage = 8000;
                low_shutdown_voltage = 7000;
                /* brickpi3 back-feeds voltage from USB between 4V and 5V */
                not_present_voltage = 4750;
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

        // FIXME: this time must match sample_period in get_bat_temp()
        timeout_id = Timeout.add (400, handle_timeout);
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

    /**
     * Get the power supply voltage by reading it from sysfs.
     * @return the voltage in mV.
     */
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
     * Get the power supply current by reading it from sysfs.
     * @return the current in mA.
     */
    int _get_current () {
        try {
            var path = Path.build_filename (device.get_sysfs_path (), "current_now");
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
     * Get the voltage that triggers a "not present" state.
     */
    public int not_present_voltage { get; private set; }

    /**
     * Get the battery state.
     */
    public BatteryState battery_state { get; private set; }

    BatteryState _get_battery_state () {
        if (voltage < not_present_voltage) {
            return BatteryState.NOT_PRESENT;
        }
        if (temperature > high_temp_shutdown) {
            return BatteryState.CRITICAL_HIGH_TEMP;
        }
        if (voltage < low_shutdown_voltage) {
            return BatteryState.CRITICAL_LOW_VOLT;
        }
        if (temperature > high_temp_warn) {
            return BatteryState.HIGH_TEMP;
        }
        if (voltage < low_warn_voltage) {
            return BatteryState.LOW_VOLT;
        }
        return BatteryState.OK;
    }

    /**
     * Poll the system battery for changes.
     */
    bool handle_timeout () {
        // have to change at least 0.05V before updating the voltage property
        var new_voltage = _get_voltage ();
        if ((voltage - new_voltage).abs () >= 50) {
            voltage = new_voltage;
        }

        if (monitor_temperature) {
            var new_current = _get_current ();
            // Debug values:
            //  new_voltage = 7000; // 7V
            //  new_current = 5000; // 5A
            // multiplying current by 1.1 comes from lms2012
            var new_temp = get_bat_temp (new_voltage / 1000f, new_current / 1000f * 1.1f);
            if ((temperature - new_temp).abs () > 0.1f) {
                temperature = new_temp;
                debug ("temperature: %.1f", temperature);
            }
        }

        var new_state = _get_battery_state ();
        if (battery_state == new_state) {
            battery_state_debounce = 0;
        }
        else {
            battery_state_debounce++;
            // FIXME: debounce time depends on how often handle_timeout() is called
            if (battery_state_debounce >= 10) {
                battery_state_debounce = 0;
                battery_state = new_state;
            }
        }

        return Source.CONTINUE;
    }

    // *************************************************************** //
    // LEGO MINDSTORMS EV3 battery temperature estimation from lms2012 //
    // *************************************************************** //

    struct bat_temp_t {
        uint index;             // Keeps track of sample index since power-on
        float I_bat_mean;       // Running mean current
        float T_bat;            // Battery temperature
        float T_elec;           // EV3 electronics temperature
        float R_bat_model_old;  // Old internal resistance of the battery model
        float R_bat;            // Internal resistance of the batteries
        // Flag that prevents initialization of R_bat when the battery is charging
        bool has_passed_7v5_flag;
    }

    bat_temp_t bat_temp;

    // Function for estimating new battery temperature based on measurements
    // of battery voltage and battery current.
    float get_bat_temp (float V_bat, float I_bat) {
        /*************************** Model parameters *******************************/
        // Approx. initial internal resistance of 6 Energizer industrial batteries:
        const float R_bat_init = 0.63468f;
        // Batteries' heat capacity:
        const float heat_cap_bat = 136.6598f;
        // Newtonian cooling constant for electronics:
        const float K_bat_loss_to_elec = -0.0003f; //-0.000789767;
        // Newtonian heating constant for electronics:
        const float K_bat_gain_from_elec = 0.001242896f; //0.001035746;
        // Newtonian cooling constant for environment:
        const float K_bat_to_room = -0.00012f;
        // Battery power Boost
        const float battery_power_boost = 1.7f;
        // Battery R_bat negative gain
        const float R_bat_neg_gain = 1.00f;

        // Slope of electronics lossless heating curve (linear!!!) [Deg.C / s]:
        const float K_elec_heat_slope = 0.0123175f;
        // Newtonian cooling constant for battery packs:
        const float K_elec_loss_to_bat = -0.004137487f;
        // Newtonian heating constant for battery packs:
        const float K_elec_gain_from_bat = 0.002027574f; //0.00152068;
        // Newtonian cooling constant for environment:
        const float K_elec_to_room = -0.001931431f; //-0.001843639;

        // FIXME: This time must match Timeout.add() in the constructor
        const float sample_period = 0.4f;   // Algorithm update period in seconds

        float R_bat_model;          // Internal resistance of the battery model
        float slope_A;              // Slope obtained by linear interpolation
        float intercept_b;          // Offset obtained by linear interpolation
        const float I_1A = 0.05f;   // Current carrying capacity at bottom of the curve
        const float I_2A = 2.0f;    // Current carrying capacity at the top of the curve

        float R_1A; // Internal resistance of the batteries at 1A and V_bat
        float R_2A; // Internal resistance of the batteries at 2A and V_bat

        float dT_bat_own;               // Batteries' own heat
        float dT_bat_loss_to_elec;      // Batteries' heat loss to electronics
        float dT_bat_gain_from_elec;    // Batteries' heat gain from electronics
        float dT_bat_loss_to_room;      // Batteries' cooling from environment

        float dT_elec_own;              // Electronics' own heat
        float dT_elec_loss_to_bat;      // Electronics' heat loss to the battery pack
        float dT_elec_gain_from_bat;    // Electronics' heat gain from battery packs
        float dT_elec_loss_to_room;     // Electronics' heat loss to the environment

        /***************************************************************************/

        // Update the average current: I_bat_mean
        if (bat_temp.index > 0) {
            bat_temp.I_bat_mean = (bat_temp.index * bat_temp.I_bat_mean + I_bat) / (bat_temp.index + 1) ;
        }
        else {
            bat_temp.I_bat_mean = I_bat;
        }

        bat_temp.index++;

        // Calculate R_1A as a function of V_bat (internal resistance at 1A continuous)
        R_1A = 0.014071f * (V_bat * V_bat * V_bat * V_bat)
             - 0.335324f * (V_bat * V_bat * V_bat)
             + 2.933404f * (V_bat * V_bat)
             - 11.243047f * V_bat
             + 16.897461f;

        // Calculate R_2A as a function of V_bat (internal resistance at 2A continuous)
        R_2A = 0.014420f * (V_bat * V_bat * V_bat * V_bat)
             - 0.316728f * (V_bat * V_bat * V_bat)
             + 2.559347f * (V_bat * V_bat)
             - 9.084076f * V_bat
             + 12.794176f;

        // Calculate the slope by linear interpolation between R_1A and R_2A
        slope_A = (R_1A - R_2A) / (I_1A - I_2A);
 
        // Calculate intercept by linear interpolation between R1_A and R2_A
        intercept_b = R_1A - slope_A * R_1A;

        // Reload R_bat_model:
        R_bat_model = slope_A * bat_temp.I_bat_mean + intercept_b;

        // Calculate batteries' internal resistance: R_bat
        if (V_bat > 7.5 && !bat_temp.has_passed_7v5_flag) {
            bat_temp.R_bat = R_bat_init; //7.5 V not passed a first time
        }
        else {
            // Only update R_bat with positive outcomes: R_bat_model - R_bat_model_old
            // R_bat updated with the change in model R_bat is not equal value in the model!
            if ((R_bat_model - bat_temp.R_bat_model_old) > 0) {
                bat_temp.R_bat += R_bat_model - bat_temp.R_bat_model_old;
            }
            else { // The negative outcome of R_bat_model added to only part of R_bat
                bat_temp.R_bat += R_bat_neg_gain * (R_bat_model - bat_temp.R_bat_model_old);
            }
            // Make sure we initialize R_bat later
            bat_temp.has_passed_7v5_flag = true;
        }

        // Save R_bat_model for use in the next function call
        bat_temp.R_bat_model_old = R_bat_model;

        // Debug code:
        //  message ("%c %f %f %f %f %f %f", bat_temp.has_passed_7v5_flag ? 'Y' : 'N',
        //      R_1A, R_2A, slope_A, intercept_b, R_bat_model - bat_temp.R_bat_model_old,
        //      bat_temp.R_bat);

        /**** Calculate the 4 types of temperature change for the batteries ****/

        // Calculate the batteries' own temperature change
        dT_bat_own = bat_temp.R_bat * I_bat * I_bat * sample_period * battery_power_boost / heat_cap_bat;

        //Calculate the batteries' heat loss to the electronics
        if (bat_temp.T_bat > bat_temp.T_elec) {
            dT_bat_loss_to_elec = K_bat_loss_to_elec * (bat_temp.T_bat - bat_temp.T_elec) * sample_period;
        }
        else {
            dT_bat_loss_to_elec = 0.0f;
        }

        // Calculate the batteries' heat gain from the electronics
        if (bat_temp.T_bat < bat_temp.T_elec) {
            dT_bat_gain_from_elec = K_bat_gain_from_elec * (bat_temp.T_elec - bat_temp.T_bat) * sample_period;
        }
        else {
            dT_bat_gain_from_elec = 0.0f;
        }

        // Calculate the batteries' heat loss to environment
        dT_bat_loss_to_room = K_bat_to_room * bat_temp.T_bat * sample_period;

        /**** Calculate the 4 types of temperature change for the electronics ****/

        // Calculate the electronics' own temperature change
        dT_elec_own = K_elec_heat_slope * sample_period;

        // Calculate the electronics' heat loss to the batteries
        if (bat_temp.T_elec > bat_temp.T_bat) {
            dT_elec_loss_to_bat = K_elec_loss_to_bat * (bat_temp.T_elec - bat_temp.T_bat) * sample_period;
        }
        else {
            dT_elec_loss_to_bat = 0.0f;
        }

        // Calculate the electronics' heat gain from the batteries
        if (bat_temp.T_elec < bat_temp.T_bat) {
            dT_elec_gain_from_bat = K_elec_gain_from_bat * (bat_temp.T_bat - bat_temp.T_elec) * sample_period;
        }
        else {
            dT_elec_gain_from_bat = 0.0f;
        }

        // Calculate the electronics' heat loss to the environment
        dT_elec_loss_to_room = K_elec_to_room * bat_temp.T_elec * sample_period;

        /*****************************************************************************/

        //  message ("%f %f %f %f %f <> %f %f %f %f %f",
        //      dT_bat_own, dT_bat_loss_to_elec,
        //      dT_bat_gain_from_elec, dT_bat_loss_to_room, bat_temp.T_bat,
        //      dT_elec_own, dT_elec_loss_to_bat, dT_elec_gain_from_bat,
        //      dT_elec_loss_to_room, bat_temp.T_elec);

        // Refresh battery temperature
        bat_temp.T_bat += dT_bat_own + dT_bat_loss_to_elec + dT_bat_gain_from_elec + dT_bat_loss_to_room;

        // Refresh electronics temperature
        bat_temp.T_elec += dT_elec_own + dT_elec_loss_to_bat + dT_elec_gain_from_bat + dT_elec_loss_to_room;

        return bat_temp.T_bat;
    }
}
