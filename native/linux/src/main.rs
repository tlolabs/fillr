use fillr_core::{
    BuildResult, Engine, MediaPolicy, Orientation, ScanType, Snapshot, Status, TARGET_MS,
    TelevisionStandard, owned_ffprobe_path,
};
use gtk::gio;
use gtk::glib;
use gtk::prelude::*;
use gtk4 as gtk;
use std::cell::RefCell;
use std::fs;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

const APP_ID: &str = "edu.chabot.news.backgrounder";

struct Overlay {
    window: gtk::Window,
    status: gtk::Label,
    time: gtk::Label,
    progress: gtk::ProgressBar,
}

struct State {
    app: gtk::Application,
    window: gtk::ApplicationWindow,
    folder_label: gtk::Label,
    status_label: gtk::Label,
    remaining_label: gtk::Label,
    available_label: gtk::Label,
    counts_label: gtk::Label,
    progress: gtk::ProgressBar,
    preview: gtk::Label,
    notes: gtk::Label,
    build_button: gtk::Button,
    folder_button: gtk::Button,
    output_button: gtk::Button,
    overlay_button: gtk::Button,
    engine: Option<Arc<Mutex<Engine>>>,
    build_result: Arc<Mutex<Option<Result<BuildResult, String>>>>,
    building: bool,
    was_ready: bool,
    last_output: Option<PathBuf>,
    overlay: Option<Overlay>,
    media_policy: MediaPolicy,
}

fn clock_text(milliseconds: u64) -> String {
    let seconds = milliseconds.saturating_add(999) / 1000;
    format!("{}:{:02}", seconds / 60, seconds % 60)
}

fn config_path() -> Option<PathBuf> {
    let root = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?;
    Some(root.join("fillr/folder"))
}

fn media_policy_path() -> Option<PathBuf> {
    config_path().map(|path| path.with_file_name("media-policy.json"))
}

fn load_media_policy() -> MediaPolicy {
    media_policy_path()
        .and_then(|path| fs::read(path).ok())
        .and_then(|data| serde_json::from_slice::<MediaPolicy>(&data).ok())
        .unwrap_or_default()
}

fn legacy_config_path() -> Option<PathBuf> {
    let root = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?;
    Some(root.join("chabot-backgrounder/folder"))
}

fn open_folder(state: &Rc<RefCell<State>>, path: PathBuf) {
    let policy = state.borrow().media_policy.clone();
    let engine = owned_ffprobe_path()
        .map_err(fillr_core::EngineError)
        .and_then(|probe| Engine::new_with_policy(&path, probe, policy));
    match engine {
        Ok(engine) => {
            let mut state = state.borrow_mut();
            state.engine = Some(Arc::new(Mutex::new(engine)));
            state.folder_label.set_text(&path.to_string_lossy());
            state.notes.set_text("");
            state.was_ready = false;
            if let Some(config) = config_path() {
                if let Some(parent) = config.parent() {
                    let _ = fs::create_dir_all(parent);
                }
                let _ = fs::write(config, path.to_string_lossy().as_bytes());
            }
        }
        Err(error) => state.borrow().notes.set_text(&error.to_string()),
    }
}

fn render(state: &Rc<RefCell<State>>, snapshot: Snapshot) {
    let mut state = state.borrow_mut();
    let ready = snapshot.status == Status::Ready;
    state.status_label.set_text(&snapshot.message);
    state
        .remaining_label
        .set_text(&clock_text(snapshot.remaining_ms));
    state
        .available_label
        .set_text(&clock_text(snapshot.available_ms));
    state.counts_label.set_text(&format!(
        "{} usable clips · {} pending",
        snapshot.clips.len(),
        snapshot.pending.len()
    ));
    state
        .progress
        .set_fraction((snapshot.available_ms.min(TARGET_MS * 14) as f64) / (TARGET_MS * 14) as f64);
    state.build_button.set_sensitive(ready && !state.building);
    state.folder_button.set_sensitive(!state.building);
    if ready {
        state.status_label.add_css_class("success");
    } else {
        state.status_label.remove_css_class("success");
    }
    let preview = snapshot
        .plan
        .as_ref()
        .map(|plan| {
            plan.assignments
                .iter()
                .map(|a| {
                    format!(
                        "Comp {:>2}   {}   {} clips",
                        a.comp,
                        clock_text(a.duration_ms),
                        a.filenames.len()
                    )
                })
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_else(|| "The 14-Comp layout will appear when enough footage is ready.".into());
    state.preview.set_text(&preview);
    state.notes.set_text(&format!(
        "{} excluded files · {} rejected deleted · {} exact duplicates deleted",
        snapshot.excluded.len(),
        snapshot.rejection_log.len(),
        snapshot.duplicate_log.len()
    ));
    if let Some(overlay) = &state.overlay {
        overlay.status.set_text(if ready {
            "Ready to build"
        } else {
            "Footage remaining"
        });
        overlay.time.set_text(&clock_text(snapshot.remaining_ms));
        overlay.progress.set_fraction(
            (snapshot.available_ms.min(TARGET_MS * 14) as f64) / (TARGET_MS * 14) as f64,
        );
    }
    if ready && !state.was_ready {
        let notification = gio::Notification::new("Chabot News footage is ready");
        notification.set_body(Some(
            "You can stop downloading and build the 14 Comp folders.",
        ));
        state.app.send_notification(Some("ready"), &notification);
    }
    state.was_ready = ready;
}

fn poll(state: &Rc<RefCell<State>>) {
    let result = state.borrow().build_result.lock().unwrap().take();
    if let Some(result) = result {
        let mut state = state.borrow_mut();
        state.building = false;
        match result {
            Ok(build) => {
                state.last_output = Some(PathBuf::from(build.output_folder));
                state.output_button.set_sensitive(true);
            }
            Err(error) => state.notes.set_text(&error),
        }
    }
    let engine = state.borrow().engine.clone();
    if let Some(engine) = engine {
        if let Ok(engine) = engine.try_lock() {
            render(state, engine.snapshot());
        }
    }
}

fn show_overlay(state: &Rc<RefCell<State>>) {
    let mut state_ref = state.borrow_mut();
    if let Some(overlay) = state_ref.overlay.take() {
        overlay.window.close();
        state_ref.overlay_button.set_label("Show Overlay");
        return;
    }
    let window = gtk::Window::builder()
        .application(&state_ref.app)
        .title("FILLR Progress")
        .default_width(280)
        .default_height(110)
        .build();
    window.set_transient_for(Some(&state_ref.window));
    let box_view = gtk::Box::new(gtk::Orientation::Vertical, 8);
    box_view.set_margin_top(14);
    box_view.set_margin_bottom(14);
    box_view.set_margin_start(14);
    box_view.set_margin_end(14);
    let status = gtk::Label::new(Some("Footage remaining"));
    let time = gtk::Label::new(Some("141:10"));
    time.add_css_class("title-2");
    let progress = gtk::ProgressBar::new();
    box_view.append(&status);
    box_view.append(&time);
    box_view.append(&progress);
    window.set_child(Some(&box_view));
    window.present();
    #[cfg(target_os = "linux")]
    {
        let overlay_window = window.clone();
        glib::idle_add_local_once(move || request_x11_above(&overlay_window));
    }
    state_ref.overlay = Some(Overlay {
        window,
        status,
        time,
        progress,
    });
    state_ref.overlay_button.set_label("Hide Overlay");
}

fn show_media_preferences(state: &Rc<RefCell<State>>) {
    let current = state.borrow().media_policy.clone();
    let parent = state.borrow().window.clone();
    let window = gtk::Window::builder()
        .title("Media preferences")
        .transient_for(&parent)
        .modal(true)
        .default_width(540)
        .default_height(650)
        .build();
    let root = gtk::Box::new(gtk::Orientation::Vertical, 10);
    root.set_margin_top(18);
    root.set_margin_bottom(18);
    root.set_margin_start(18);
    root.set_margin_end(18);
    let explain = gtk::Label::new(Some(
        "NTSC 1080i is the default. Rejected files are deleted only after a final name and 10 unchanged seconds.",
    ));
    explain.set_wrap(true);
    explain.set_xalign(0.0);
    root.append(&explain);
    let enabled = gtk::CheckButton::with_label("Filter media");
    enabled.set_active(current.enabled);
    root.append(&enabled);
    let delete = gtk::CheckButton::with_label("Delete rejected completed downloads");
    delete.set_active(current.delete_rejected);
    root.append(&delete);
    let fields = gtk::Box::new(gtk::Orientation::Vertical, 8);
    let field = |label: &str, value: String| {
        let row = gtk::Box::new(gtk::Orientation::Vertical, 3);
        let title = gtk::Label::new(Some(label));
        title.set_xalign(0.0);
        let entry = gtk::Entry::new();
        entry.set_text(&value);
        row.append(&title);
        row.append(&entry);
        fields.append(&row);
        entry
    };
    let extensions = field(
        "Allowed extensions (comma separated)",
        current.allowed_extensions.join(", "),
    );
    let containers = field("Allowed containers", current.allowed_containers.join(", "));
    let codecs = field("Allowed video codecs", current.allowed_codecs.join(", "));
    let width = field(
        "Required width (blank = any)",
        current
            .required_width
            .map(|v| v.to_string())
            .unwrap_or_default(),
    );
    let height = field(
        "Required height (blank = any)",
        current
            .required_height
            .map(|v| v.to_string())
            .unwrap_or_default(),
    );
    let standard = gtk::DropDown::from_strings(&["any", "ntsc", "pal"]);
    standard.set_selected(match current.television_standard {
        TelevisionStandard::Any => 0,
        TelevisionStandard::Ntsc => 1,
        TelevisionStandard::Pal => 2,
    });
    let standard_label = gtk::Label::new(Some("TV standard"));
    standard_label.set_xalign(0.0);
    fields.append(&standard_label);
    fields.append(&standard);
    let rate = field(
        "Frame rate (blank = any)",
        current.frame_rate.unwrap_or_default(),
    );
    let scan = gtk::DropDown::from_strings(&["any", "interlaced", "progressive"]);
    scan.set_selected(match current.scan_type {
        ScanType::Any => 0,
        ScanType::Interlaced => 1,
        ScanType::Progressive => 2,
    });
    let scan_label = gtk::Label::new(Some("Scan type"));
    scan_label.set_xalign(0.0);
    fields.append(&scan_label);
    fields.append(&scan);
    let orientation = gtk::DropDown::from_strings(&["any", "horizontal", "vertical"]);
    orientation.set_selected(match current.orientation {
        Orientation::Any => 0,
        Orientation::Horizontal => 1,
        Orientation::Vertical => 2,
    });
    let orientation_label = gtk::Label::new(Some("Orientation"));
    orientation_label.set_xalign(0.0);
    fields.append(&orientation_label);
    fields.append(&orientation);
    let aspect = field(
        "Display aspect ratio (blank = any)",
        current.display_aspect_ratio.unwrap_or_default(),
    );
    let scroll = gtk::ScrolledWindow::new();
    scroll.set_vexpand(true);
    scroll.set_child(Some(&fields));
    root.append(&scroll);
    let error = gtk::Label::new(None);
    error.set_wrap(true);
    error.set_xalign(0.0);
    root.append(&error);
    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let cancel = gtk::Button::with_label("Cancel");
    let save = gtk::Button::with_label("Save preferences");
    save.add_css_class("suggested-action");
    buttons.append(&cancel);
    buttons.append(&save);
    root.append(&buttons);
    window.set_child(Some(&root));
    let close_window = window.clone();
    cancel.connect_clicked(move |_| close_window.close());
    let save_window = window.clone();
    let save_state = state.clone();
    save.connect_clicked(move |_| {
        let list = |entry: &gtk::Entry| {
            entry
                .text()
                .split(',')
                .map(|s| s.trim().to_owned())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
        };
        let dimension = |entry: &gtk::Entry| -> Result<Option<u32>, String> {
            let text = entry.text();
            let trimmed = text.trim();
            if trimmed.is_empty() {
                return Ok(None);
            }
            trimmed
                .parse::<u32>()
                .ok()
                .filter(|value| *value > 0)
                .map(Some)
                .ok_or_else(|| "Width and height must be positive whole numbers".to_owned())
        };
        let optional = |entry: &gtk::Entry| {
            let value = entry.text().trim().to_owned();
            if value.is_empty() { None } else { Some(value) }
        };
        let policy = (|| -> Result<MediaPolicy, String> {
            let policy = MediaPolicy {
                enabled: enabled.is_active(),
                delete_rejected: delete.is_active(),
                allowed_extensions: list(&extensions),
                allowed_containers: list(&containers),
                allowed_codecs: list(&codecs),
                required_width: dimension(&width)?,
                required_height: dimension(&height)?,
                television_standard: match standard.selected() {
                    1 => TelevisionStandard::Ntsc,
                    2 => TelevisionStandard::Pal,
                    _ => TelevisionStandard::Any,
                },
                frame_rate: optional(&rate),
                scan_type: match scan.selected() {
                    1 => ScanType::Interlaced,
                    2 => ScanType::Progressive,
                    _ => ScanType::Any,
                },
                orientation: match orientation.selected() {
                    1 => Orientation::Horizontal,
                    2 => Orientation::Vertical,
                    _ => Orientation::Any,
                },
                display_aspect_ratio: optional(&aspect),
            };
            policy.validate()?;
            Ok(policy)
        })();
        let result = policy.and_then(|policy| {
            if let Some(engine) = &save_state.borrow().engine {
                engine
                    .lock()
                    .unwrap()
                    .set_policy(policy.clone())
                    .map_err(|e| e.to_string())?;
            }
            if let Some(path) = media_policy_path() {
                if let Some(parent) = path.parent() {
                    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
                }
                fs::write(
                    path,
                    serde_json::to_vec_pretty(&policy).map_err(|e| e.to_string())?,
                )
                .map_err(|e| e.to_string())?;
            }
            save_state.borrow_mut().media_policy = policy;
            Ok(())
        });
        match result {
            Ok(()) => save_window.close(),
            Err(message) => error.set_text(&message),
        }
    });
    window.present();
}

#[cfg(target_os = "linux")]
fn request_x11_above(window: &gtk::Window) {
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{ClientMessageEvent, ConnectionExt, EventMask};

    let Some(surface) = window.surface() else {
        return;
    };
    let Ok(surface) = surface.downcast::<gdk4_x11::X11Surface>() else {
        return;
    };
    let Ok((connection, screen)) = x11rb::connect(None) else {
        return;
    };
    let Ok(state) = connection.intern_atom(false, b"_NET_WM_STATE") else {
        return;
    };
    let Ok(above) = connection.intern_atom(false, b"_NET_WM_STATE_ABOVE") else {
        return;
    };
    let (Ok(state), Ok(above)) = (state.reply(), above.reply()) else {
        return;
    };
    let event = ClientMessageEvent::new(
        32,
        surface.xid() as u32,
        state.atom,
        [1, above.atom, 0, 1, 0],
    );
    let root = connection.setup().roots[screen].root;
    if connection
        .send_event(
            false,
            root,
            EventMask::SUBSTRUCTURE_NOTIFY | EventMask::SUBSTRUCTURE_REDIRECT,
            event,
        )
        .is_ok()
    {
        let _ = connection.flush();
    }
}

fn activate(app: &gtk::Application) {
    let window = gtk::ApplicationWindow::builder()
        .application(app)
        .title("FILLR")
        .default_width(680)
        .default_height(650)
        .build();
    let root = gtk::Box::new(gtk::Orientation::Vertical, 16);
    root.set_margin_top(20);
    root.set_margin_bottom(20);
    root.set_margin_start(20);
    root.set_margin_end(20);
    let title = gtk::Label::new(Some("FILLR"));
    title.add_css_class("title-1");
    title.set_xalign(0.0);
    root.append(&title);
    let controls = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let folder_button = gtk::Button::with_label("Choose CNN Download Folder…");
    let media_button = gtk::Button::with_label("Media Preferences…");
    let refresh_button = gtk::Button::with_label("Refresh");
    let overlay_button = gtk::Button::with_label("Show Overlay");
    controls.append(&folder_button);
    controls.append(&media_button);
    controls.append(&refresh_button);
    controls.append(&overlay_button);
    root.append(&controls);
    let folder_label = gtk::Label::new(Some("Choose the folder where CNN MPG files arrive"));
    folder_label.set_xalign(0.0);
    folder_label.set_wrap(true);
    root.append(&folder_label);
    let status_label = gtk::Label::new(Some("Choose a download folder"));
    status_label.add_css_class("title-3");
    status_label.set_xalign(0.0);
    root.append(&status_label);
    let countdown = gtk::Label::new(Some("Remaining to 141:10"));
    countdown.set_xalign(0.0);
    root.append(&countdown);
    let remaining_label = gtk::Label::new(Some("141:10"));
    remaining_label.add_css_class("title-1");
    remaining_label.set_xalign(0.0);
    root.append(&remaining_label);
    let available_label = gtk::Label::new(Some("0:00 unique footage"));
    available_label.set_xalign(0.0);
    root.append(&available_label);
    let counts_label = gtk::Label::new(Some("0 usable clips"));
    counts_label.set_xalign(0.0);
    root.append(&counts_label);
    let progress = gtk::ProgressBar::new();
    root.append(&progress);
    let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let build_button = gtk::Button::with_label("Build Comp Folders");
    build_button.add_css_class("suggested-action");
    build_button.set_sensitive(false);
    let output_button = gtk::Button::with_label("Open Last Export");
    output_button.set_sensitive(false);
    actions.append(&build_button);
    actions.append(&output_button);
    root.append(&actions);
    let preview_title = gtk::Label::new(Some("Comp preview"));
    preview_title.add_css_class("title-3");
    preview_title.set_xalign(0.0);
    root.append(&preview_title);
    let preview = gtk::Label::new(Some(
        "The 14-Comp layout will appear when enough footage is ready.",
    ));
    preview.set_xalign(0.0);
    preview.set_selectable(true);
    let scroll = gtk::ScrolledWindow::new();
    scroll.set_vexpand(true);
    scroll.set_child(Some(&preview));
    root.append(&scroll);
    let notes = gtk::Label::new(None);
    notes.set_xalign(0.0);
    notes.set_wrap(true);
    root.append(&notes);
    window.set_child(Some(&root));

    let state = Rc::new(RefCell::new(State {
        app: app.clone(),
        window: window.clone(),
        folder_label,
        status_label,
        remaining_label,
        available_label,
        counts_label,
        progress,
        preview,
        notes,
        build_button: build_button.clone(),
        folder_button: folder_button.clone(),
        output_button: output_button.clone(),
        overlay_button: overlay_button.clone(),
        engine: None,
        build_result: Arc::new(Mutex::new(None)),
        building: false,
        was_ready: false,
        last_output: None,
        overlay: None,
        media_policy: load_media_policy(),
    }));
    let chooser_state = state.clone();
    folder_button.connect_clicked(move |_| {
        let parent = chooser_state.borrow().window.clone();
        let dialog = gtk::FileChooserNative::new(
            Some("Choose CNN download folder"),
            Some(&parent),
            gtk::FileChooserAction::SelectFolder,
            Some("Choose"),
            Some("Cancel"),
        );
        let selected_state = chooser_state.clone();
        dialog.connect_response(move |dialog, response| {
            if response == gtk::ResponseType::Accept {
                if let Some(path) = dialog.file().and_then(|file| file.path()) {
                    open_folder(&selected_state, path);
                }
            }
            dialog.destroy();
        });
        dialog.show();
    });
    let refresh_state = state.clone();
    let media_state = state.clone();
    media_button.connect_clicked(move |_| show_media_preferences(&media_state));
    refresh_button.connect_clicked(move |_| {
        if let Some(engine) = &refresh_state.borrow().engine {
            if let Ok(engine) = engine.try_lock() {
                engine.refresh();
            }
        }
        poll(&refresh_state);
    });
    let overlay_state = state.clone();
    overlay_button.connect_clicked(move |_| show_overlay(&overlay_state));
    let build_state = state.clone();
    build_button.connect_clicked(move |_| {
        let engine = build_state.borrow().engine.clone();
        let Some(engine) = engine else { return };
        let results = build_state.borrow().build_result.clone();
        build_state.borrow_mut().building = true;
        build_state.borrow().build_button.set_sensitive(false);
        thread::spawn(move || {
            let outcome = engine.lock().unwrap().build().map_err(|e| e.to_string());
            *results.lock().unwrap() = Some(outcome);
        });
    });
    let output_state = state.clone();
    output_button.connect_clicked(move |_| {
        if let Some(path) = &output_state.borrow().last_output {
            let uri = gio::File::for_path(path).uri();
            let _ = gio::AppInfo::launch_default_for_uri(&uri, None::<&gio::AppLaunchContext>);
        }
    });
    let timer_state = state.clone();
    glib::timeout_add_local(Duration::from_secs(1), move || {
        poll(&timer_state);
        glib::ControlFlow::Continue
    });
    if let Some(config) = config_path()
        .filter(|path| path.is_file())
        .or_else(legacy_config_path)
    {
        if let Ok(path) = fs::read_to_string(config) {
            open_folder(&state, PathBuf::from(path.trim()));
        }
    }
    window.present();
}

fn main() {
    let app = gtk::Application::builder().application_id(APP_ID).build();
    app.connect_activate(activate);
    app.run();
}
