/*
 * board_info.vala
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

public errordomain BoardInfoError {
    FAILED,
    NOT_FOUND
}

public class BoardInfo : Object {
    Device device;

    public BoardInfo (string board_type) throws BoardInfoError {
        var client = new Client (null);
        var enumerator = new Enumerator (client);
        enumerator.add_match_subsystem ("board-info");
        enumerator.add_match_property ("BOARD_INFO_TYPE", board_type);
        var list = enumerator.execute ();
        if (list.length () == 0) {
            throw new BoardInfoError.NOT_FOUND ("Could not find type '%s'".printf (board_type));
        }
        device = list.data;
    }

    public string? serial_number {
        get {
            return device.get_property ("BOARD_INFO_SERIAL_NUM");
        }
    }
}
