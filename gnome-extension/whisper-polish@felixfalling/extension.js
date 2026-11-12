// Whisper Controls: the Whisper and Cleanup buttons in GNOME's system menu, and the
// microphone in the top bar that shows what dictation is doing.
//
// Nothing here polls. It used to run `whisper-ui.py status` every three seconds, a Python
// process each time (28,800 a day, more CPU than the dictation service itself used).
// Now three things report changes as they happen:
//   - systemd says when whisper-ptt.service starts or stops, over D-Bus;
//   - the service rewrites $XDG_RUNTIME_DIR/whisper-ptt/status.json when a dictation
//     begins, is being transcribed, ends or fails (Status in whisper-ptt.py);
//   - ~/.local/state/whisper-ptt/polish changes when Cleanup is switched, here, from the
//     command line or from the Mac.
// So a switch flipped anywhere else shows here at once.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';

const HOME = GLib.get_home_dir();
const UNIT = 'whisper-ptt.service';
const HELPER = GLib.build_filenamev([HOME, '.local', 'share', 'whisper-ptt', 'bin', 'whisper-ui.py']);
const CLI = GLib.build_filenamev([HOME, '.local', 'bin', 'whisper-ptt']);
const CONFIG = GLib.build_filenamev([HOME, '.config', 'whisper-ptt', 'config.json']);
const POLISH_STATE = GLib.build_filenamev([HOME, '.local', 'state', 'whisper-ptt', 'polish']);
const STATUS = GLib.build_filenamev([GLib.get_user_runtime_dir(), 'whisper-ptt', 'status.json']);

const SYSTEMD = 'org.freedesktop.systemd1';
const MANAGER_PATH = '/org/freedesktop/systemd1';
const MIC_ICON = 'audio-input-microphone-symbolic';
const BUSY_ICON = 'content-loading-symbolic';

function cancelled(error) {
    return error?.matches?.(Gio.io_error_quark(), Gio.IOErrorEnum.CANCELLED) ?? false;
}

const WhisperIndicator = GObject.registerClass(
class WhisperIndicator extends QuickSettings.SystemIndicator {
    _init() {
        super._init();
        this._dead = false;
        this._cancel = new Gio.Cancellable();
        this._monitors = [];
        this._bus = null;
        this._unitPath = null;
        this._unitSignal = 0;
        this._retry = 0;
        this._retryUnit = 0;
        this._copied = 0;
        this._statusRead = 0;

        // What is known. unit is systemd's ActiveState, or 'unknown' until it has answered.
        this._unit = 'unknown';
        this._polish = true;
        this._status = null;            // the service's status.json, when it has written one
        this._stalePid = null;          // whose status.json was there when the service last started
        this._switching = null;         // 'on' | 'off' | 'cleanup' while a command runs

        this._icon = this._addIndicator();
        this._icon.iconName = MIC_ICON;
        this._icon.visible = false;

        this._whisper = new QuickSettings.QuickMenuToggle({
            title: 'Whisper', subtitle: 'Checking…', iconName: MIC_ICON, toggleMode: true,
        });
        this._cleanup = new QuickSettings.QuickToggle({
            title: 'Cleanup', subtitle: '', iconName: 'tools-check-spelling-symbolic', toggleMode: true,
        });
        this.quickSettingsItems.push(this._whisper, this._cleanup);
        this._whisper.connect('clicked', () => this._switch('all', this._whisper.checked));
        this._cleanup.connect('clicked', () => this._switch('polish', this._cleanup.checked));
        this._buildMenu();
        this._render();

        this._watch(POLISH_STATE, () => this._readPolish());
        this._watch(STATUS, () => this._readStatus());
        this._readPolish();
        this._readStatus();
        this._connectSystemd();
    }

    // ---- the menu behind the Whisper button

    _buildMenu() {
        const menu = this._whisper.menu;
        menu.setHeader(MIC_ICON, 'Whisper', '');
        this._microphones = new PopupMenu.PopupSubMenuMenuItem('Microphone', true);
        this._microphones.icon.icon_name = MIC_ICON;
        menu.addMenuItem(this._microphones);
        this._copy = menu.addAction('Copy Last Dictation', () => this._copyLast(), 'edit-copy-symbolic');
        menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        menu.addAction('Show Log', () => this._launch(() => {
            const app = Gio.AppInfo.create_from_commandline(
                `${GLib.shell_quote(CLI)} logs --follow`, 'Whisper Log', Gio.AppInfoCreateFlags.NEEDS_TERMINAL);
            app.launch([], global.create_app_launch_context(0, -1));
        }));
        menu.addAction('Open Settings File', () => this._launch(() => {
            Gio.AppInfo.launch_default_for_uri(
                GLib.filename_to_uri(CONFIG, null), global.create_app_launch_context(0, -1));
        }));
        // The microphones are looked up when the menu opens, not kept up to date all day.
        menu.connect('open-state-changed', (_menu, open) => {
            if (open)
                this._loadMicrophones();
        });
    }

    _launch(what) {
        try {
            what();
            Main.panel.closeQuickSettings();
        } catch (error) {
            Main.notifyError('Whisper', error.message);
        }
    }

    _copyLast() {
        const text = this._status?.last;
        if (!text)
            return;
        St.Clipboard.get_default().set_text(St.ClipboardType.CLIPBOARD, text);
        // Choosing an item closes this menu, so the Whisper button says it for a moment.
        if (this._copied)
            GLib.source_remove(this._copied);
        this._copied = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1500, () => {
            this._copied = 0;
            if (!this._dead)
                this._render();
            return GLib.SOURCE_REMOVE;
        });
        this._render();
    }

    _loadMicrophones() {
        const list = this._microphones.menu;
        if (list.isEmpty()) {
            const waiting = new PopupMenu.PopupMenuItem('Looking…');
            waiting.setSensitive(false);
            list.addMenuItem(waiting);
        }
        this._run([CLI, 'mic', '--json'], (error, output) => {
            let found;
            try {
                if (error)
                    throw error;
                found = JSON.parse(output);
            } catch (problem) {
                list.removeAll();
                const failed = new PopupMenu.PopupMenuItem('Could not list microphones');
                failed.setSensitive(false);
                list.addMenuItem(failed);
                console.warn(`whisper-ptt: ${problem.message}`);
                return;
            }
            list.removeAll();
            const add = (label, name, chosen) => {
                const item = new PopupMenu.PopupMenuItem(label);
                item.setOrnament(chosen ? PopupMenu.Ornament.CHECK : PopupMenu.Ornament.NONE);
                item.connect('activate', () => this._chooseMicrophone(name));
                list.addMenuItem(item);
            };
            add('System Default', 'default', !found.wanted);
            for (const mic of found.microphones)
                add(mic.description, mic.name, mic.chosen);
            if (found.wanted && !found.connected) {
                const missing = new PopupMenu.PopupMenuItem(`${found.wanted} (not connected)`);
                missing.setOrnament(PopupMenu.Ornament.CHECK);
                missing.setSensitive(false);
                list.addMenuItem(missing);
            }
        });
    }

    _chooseMicrophone(name) {
        // `whisper-ptt mic` saves the choice and restarts the service; systemd reports that.
        this._run([CLI, 'mic', name], error => {
            if (error)
                Main.notifyError('Whisper', error.message);
        });
    }

    // ---- commands

    _run(argv, done) {
        try {
            const proc = Gio.Subprocess.new(argv,
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
            proc.communicate_utf8_async(null, this._cancel, (process, result) => {
                if (this._dead)
                    return;
                try {
                    const [, stdout, stderr] = process.communicate_utf8_finish(result);
                    done(process.get_successful() ? null : new Error(stderr.trim() || 'Command failed'), stdout);
                } catch (error) {
                    if (!cancelled(error))
                        done(error, '');
                }
            });
        } catch (error) {
            if (!this._dead)
                done(error, '');
        }
    }

    _switch(kind, on) {
        if (this._switching) {
            this._render();             // put the button back; one command at a time
            return;
        }
        this._switching = kind === 'polish' ? 'cleanup' : on ? 'on' : 'off';
        this._render();
        this._run(['python3', HELPER, kind, on ? 'on' : 'off'], error => {
            this._switching = null;
            if (error)
                Main.notifyError('Whisper', error.message);
            // The watchers report what changed; asking once more costs nothing and covers
            // a command that failed halfway.
            this._readUnit();
            this._readPolish();
            this._render();
        });
    }

    // ---- what the service is doing: two small files

    _watch(path, changed) {
        try {
            // inotify needs the folder to exist. Both are this user's alone.
            GLib.mkdir_with_parents(GLib.path_get_dirname(path), 0o700);
            const monitor = Gio.File.new_for_path(path).monitor_file(Gio.FileMonitorFlags.NONE, null);
            monitor.set_rate_limit(50);
            monitor.connect('changed', () => {
                if (!this._dead)
                    changed();
            });
            this._monitors.push(monitor);
        } catch (error) {
            console.warn(`whisper-ptt: cannot watch ${path}: ${error.message}`);
        }
    }

    _read(path, done) {
        Gio.File.new_for_path(path).load_contents_async(this._cancel, (file, result) => {
            let text = null;
            try {
                const [, bytes] = file.load_contents_finish(result);
                text = new TextDecoder().decode(bytes);
            } catch (error) {
                if (cancelled(error))
                    return;
            }
            if (!this._dead)
                done(text);
        });
    }

    _readStatus() {
        const read = ++this._statusRead;
        this._read(STATUS, text => {
            if (read !== this._statusRead)
                return;                 // a newer read is on its way
            let status = null;
            try {
                status = text ? JSON.parse(text) : null;
            } catch {
                return;                 // caught mid-replacement; the next event has it whole
            }
            this._status = status && typeof status === 'object' ? status : null;
            this._render();
        });
    }

    _readPolish() {
        // The switch's own file; before it was ever flipped, the setting in config.json.
        this._read(POLISH_STATE, text => {
            if (text !== null) {
                this._polish = text.trim() === 'on';
                this._render();
                return;
            }
            this._read(CONFIG, config => {
                try {
                    this._polish = JSON.parse(config).polish !== false;
                } catch {
                    this._polish = true;
                }
                this._render();
            });
        });
    }

    // ---- whether the service runs: systemd, over the user bus

    _connectSystemd() {
        // By address, not Gio.DBus.session: it is the same bus in a normal session, and it
        // is where the user's systemd is even when the shell was given another one.
        const address = `unix:path=${GLib.get_user_runtime_dir()}/bus`;
        Gio.DBusConnection.new_for_address(address,
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
            null, this._cancel, (_source, result) => {
                let bus;
                try {
                    bus = Gio.DBusConnection.new_for_address_finish(result);
                } catch (error) {
                    if (!cancelled(error) && !this._dead) {
                        console.warn(`whisper-ptt: no user bus: ${error.message}`);
                        this._retrySystemd();
                    }
                    return;
                }
                bus.set_exit_on_close(false);   // losing this bus must never take the shell down
                if (this._dead) {
                    bus.close(null, null);
                    return;
                }
                this._bus = bus;
                bus.connect('closed', () => {
                    if (this._bus !== bus)
                        return;
                    this._dropBus();
                    this._unit = 'unknown';
                    this._render();
                    this._retrySystemd();
                });
                // Without Subscribe, systemd sends this client no signals.
                this._call(MANAGER_PATH, `${SYSTEMD}.Manager`, 'Subscribe', null, null, () => this._readUnit());
            });
    }

    _retrySystemd() {
        if (this._retry || this._dead)
            return;
        this._retry = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 10, () => {
            this._retry = 0;
            if (!this._dead)
                this._connectSystemd();
            return GLib.SOURCE_REMOVE;
        });
    }

    _dropBus() {
        if (this._bus && this._unitSignal)
            this._bus.signal_unsubscribe(this._unitSignal);
        this._unitSignal = 0;
        this._unitPath = null;
        this._bus = null;
    }

    _call(path, iface, method, parameters, replyType, done) {
        const bus = this._bus;
        if (!bus)
            return;
        bus.call(SYSTEMD, path, iface, method, parameters,
            replyType ? new GLib.VariantType(replyType) : null,
            Gio.DBusCallFlags.NONE, 5000, this._cancel, (connection, result) => {
                let reply = null, error = null;
                try {
                    reply = connection.call_finish(result);
                } catch (problem) {
                    if (cancelled(problem))
                        return;
                    error = problem;
                }
                if (!this._dead && this._bus === bus)
                    done(error, reply);
            });
    }

    _readUnit() {
        // LoadUnit also answers for a unit systemd has unloaded because it is stopped.
        this._call(MANAGER_PATH, `${SYSTEMD}.Manager`, 'LoadUnit',
            new GLib.Variant('(s)', [UNIT]), '(o)', (error, reply) => {
                if (error) {
                    console.warn(`whisper-ptt: ${error.message}`);
                    this._unitUnknown();
                    return;
                }
                const [path] = reply.deepUnpack();
                if (path !== this._unitPath) {
                    if (this._unitSignal)
                        this._bus.signal_unsubscribe(this._unitSignal);
                    this._unitPath = path;
                    this._unitSignal = this._bus.signal_subscribe(
                        SYSTEMD, 'org.freedesktop.DBus.Properties', 'PropertiesChanged', path,
                        `${SYSTEMD}.Unit`, Gio.DBusSignalFlags.NONE,
                        (_bus, _sender, _path, _iface, _signal, parameters) => {
                            if (this._dead)
                                return;
                            const state = parameters.deepUnpack()[1].ActiveState;
                            if (state)
                                this._setUnit(state.deepUnpack());
                            else
                                this._readUnit();
                        });
                }
                this._call(path, 'org.freedesktop.DBus.Properties', 'Get',
                    new GLib.Variant('(ss)', [`${SYSTEMD}.Unit`, 'ActiveState']), '(v)', (problem, value) => {
                        if (problem)
                            this._unitUnknown();
                        else
                            this._setUnit(value.deepUnpack()[0].deepUnpack());
                    });
            });
    }

    // systemd did not answer (busy, or reloading). Ask again rather than stay "Unavailable".
    _unitUnknown() {
        this._setUnit('unknown');
        if (this._retryUnit || this._dead)
            return;
        this._retryUnit = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 10, () => {
            this._retryUnit = 0;
            if (!this._dead)
                this._readUnit();
            return GLib.SOURCE_REMOVE;
        });
    }

    _setUnit(state) {
        if (state === this._unit)
            return;
        // A service that has just started takes a moment to write its status. What is in
        // the file until then is the previous run's ("Ready"), so it is told apart by pid.
        if (state === 'active' && this._unit !== 'unknown')
            this._stalePid = this._status?.pid ?? null;
        this._unit = state;
        this._readStatus();
        this._render();
    }

    // ---- drawing

    _render() {
        if (this._dead)
            return;
        const unit = this._unit;
        const on = unit === 'active' || unit === 'activating' || unit === 'reloading';
        let status = unit === 'active' ? this._status : null;
        if (status && this._stalePid !== null && status.pid === this._stalePid)
            status = {state: 'starting'};
        let subtitle = '', detail = null, icon = MIC_ICON, look = null;

        if (unit === 'unknown') {
            subtitle = 'Unavailable';
        } else if (unit === 'failed') {
            subtitle = 'Stopped by an error';
        } else if (unit === 'activating') {
            subtitle = 'Starting…';
            icon = BUSY_ICON;
        } else if (unit === 'deactivating') {
            subtitle = 'Stopping…';
        } else if (!on) {
            subtitle = 'Off';
        } else if (!status) {
            subtitle = 'On';
        } else if (status.state === 'starting') {
            subtitle = 'Loading…';
            icon = BUSY_ICON;
        } else if (status.state === 'recording') {
            subtitle = 'Listening…';
            icon = 'media-record-symbolic';
            look = 'whisper-ptt-recording';
        } else if (status.state === 'working') {
            subtitle = 'Transcribing…';
            icon = BUSY_ICON;
        } else if (status.note) {
            subtitle = 'Needs attention';       // the button is narrow; the menu says what
            detail = status.note;
            icon = 'dialog-warning-symbolic';
            look = 'whisper-ptt-problem';
        } else {
            subtitle = 'Ready';
        }
        if (this._switching === 'on')
            subtitle = 'Switching on…';
        else if (this._switching === 'off')
            subtitle = 'Switching off…';

        // No `reactive` here: on a button with a menu the shell applies it to the arrow
        // only, which would lock the menu (the log, the settings file) just when something
        // is wrong. _switch takes one command at a time anyway.
        this._whisper.set({checked: on, subtitle: this._copied ? 'Copied' : subtitle});
        this._cleanup.set({
            checked: this._polish,
            subtitle: !on ? 'Whisper off' : this._polish ? 'Rewrite' : 'As spoken',
            reactive: on && !this._switching,
        });

        this._icon.visible = on;
        this._icon.iconName = icon;
        for (const name of ['whisper-ptt-recording', 'whisper-ptt-problem']) {
            if (name === look)
                this._icon.add_style_class_name(name);
            else
                this._icon.remove_style_class_name(name);
        }

        const microphone = status?.microphone || '';
        this._whisper.menu.setHeader(MIC_ICON, 'Whisper', detail ?? subtitle);
        this._microphones.label.text = microphone ? `Microphone: ${microphone}` : 'Microphone';
        this._microphones.setSensitive(unit !== 'unknown');
        const last = this._status?.last || '';
        this._copy.setSensitive(!!last);
        const preview = last.length > 26 ? `${last.slice(0, 25).trimEnd()}…` : last;
        this._copy.label.text = last ? `Copy “${preview}”` : 'Copy Last Dictation';
    }

    // Whisper first, Cleanup after it. The shell adds an extension's buttons in order only
    // when the extension starts after its own menu is built; one enabled at login got them
    // back to front.
    arrange() {
        this._whisper.get_parent()?.set_child_below_sibling(this._whisper, this._cleanup);
    }

    destroy() {
        this._dead = true;
        this._cancel.cancel();
        for (const id of [this._retry, this._retryUnit, this._copied]) {
            if (id)
                GLib.source_remove(id);
        }
        this._retry = this._retryUnit = this._copied = 0;
        this._monitors.forEach(monitor => monitor.cancel());
        this._monitors = [];
        const bus = this._bus;
        this._dropBus();
        bus?.close(null, null);
        // The shell does not destroy a button's menu with the button. Left alone, the menu
        // and everything it refers to stayed behind on every disable, which is every time
        // the screen locks.
        this._whisper.menu.destroy();
        this.quickSettingsItems.forEach(item => item.destroy());
        super.destroy();
    }
});

export default class WhisperControls extends Extension {
    enable() {
        this._indicator = new WhisperIndicator();
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
        this._indicator.arrange();
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
