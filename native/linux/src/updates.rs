use super::*;
use std::process::Command;
use std::sync::mpsc;

static COMMAND_GATE: Mutex<()> = Mutex::new(());
static RESTART_IMAGE: Mutex<Option<PathBuf>> = Mutex::new(None);

// Replace this process after the GTK event loop has ended. Starting a second
// unique application before quitting can merely activate the old instance.
pub(super) fn restart_after_exit() {
    if let Some(path) = RESTART_IMAGE.lock().unwrap().take() {
        use std::os::unix::process::CommandExt;
        let error = Command::new(path).exec();
        eprintln!("FILLR could not restart: {error}. Reopen the AppImage manually.");
    }
}

fn helper(command: &str, version: Option<&str>) -> Result<serde_json::Value, String> {
    let _guard = COMMAND_GATE
        .lock()
        .map_err(|_| "Update worker unavailable".to_owned())?;
    let executable = std::env::current_exe().map_err(|e| e.to_string())?;
    let mut child = Command::new(executable.with_file_name("fillr-update"));
    child.arg(command);
    if let Some(version) = version {
        child.arg(version);
    }
    let output = child.output().map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().into());
    }
    serde_json::from_slice(&output.stdout).map_err(|e| e.to_string())
}
fn message(state: &Rc<RefCell<State>>, title: &str, body: &str) {
    let dialog = gtk::MessageDialog::builder()
        .transient_for(&state.borrow().window)
        .modal(true)
        .text(title)
        .secondary_text(body)
        .buttons(gtk::ButtonsType::Close)
        .build();
    dialog.connect_response(|dialog, _| dialog.close());
    dialog.present();
}
fn perform(
    state: Rc<RefCell<State>>,
    command: &'static str,
    version: Option<String>,
    manual: bool,
) {
    if state.borrow().building
        || state.borrow().preferences_open
        || state.borrow().update_busy
        || state.borrow().update_checking
    {
        return;
    }
    let installing = command == "install-appimage";
    state.borrow_mut().update_busy = installing;
    state.borrow_mut().update_checking = !installing;
    if installing {
        state.borrow().build_button.set_sensitive(false);
    }
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let _ = tx.send(helper(command, version.as_deref()));
    });
    glib::timeout_add_local(Duration::from_millis(150), move || {
        let result = match rx.try_recv() {
            Ok(value) => value,
            Err(mpsc::TryRecvError::Empty) => return glib::ControlFlow::Continue,
            Err(_) => Err("The update worker stopped. FILLR can continue normally.".into()),
        };
        state.borrow_mut().update_busy = false;
        state.borrow_mut().update_checking = false;
        match result {
            Err(error) => {
                if manual {
                    message(
                        &state,
                        "Update unavailable",
                        &format!(
                            "{error}\n\nManual downloads: https://github.com/tlolabs/fillr/releases/latest"
                        ),
                    );
                }
            }
            Ok(value) if value["status"] == "installed" => {
                let dialog = gtk::MessageDialog::builder()
                    .transient_for(&state.borrow().window)
                    .modal(true)
                    .text("Update installed")
                    .secondary_text(format!(
                        "Restart FILLR to use the new version. Recovery copy: {}",
                        value["backup"].as_str().unwrap_or("")
                    ))
                    .buttons(gtk::ButtonsType::None)
                    .build();
                dialog.add_button("Later", gtk::ResponseType::Cancel);
                dialog.add_button("Restart FILLR", gtk::ResponseType::Accept);
                let restart_state = state.clone();
                dialog.connect_response(move |dialog, response| {
                    dialog.close();
                    if response == gtk::ResponseType::Accept
                        && !restart_state.borrow().building
                        && !restart_state.borrow().preferences_open
                        && let Some(path) = std::env::var_os("APPIMAGE")
                    {
                        *RESTART_IMAGE.lock().unwrap() = Some(PathBuf::from(path));
                        restart_state.borrow().app.quit();
                    }
                });
                dialog.present();
            }
            Ok(value) if value["available"] == true => {
                if !manual || state.borrow().preferences_open || state.borrow().building {
                    state
                        .borrow()
                        .update_label
                        .set_text("A stable FILLR update is available.");
                } else {
                    let version = value["version"].as_str().unwrap_or("").to_owned();
                    let dialog=gtk::MessageDialog::builder().transient_for(&state.borrow().window).modal(true)
                        .text(format!("Update FILLR to {version}?"))
                        .secondary_text(format!("Download, authenticate, and replace this AppImage? A recovery copy will be retained. Restart happens only when you choose.\nRelease notes: {}",value["notes_url"].as_str().unwrap_or("")))
                        .buttons(gtk::ButtonsType::None).build();
                    dialog.add_button("Later", gtk::ResponseType::Cancel);
                    dialog.add_button("Install Update", gtk::ResponseType::Accept);
                    let install_state = state.clone();
                    dialog.connect_response(move |dialog, response| {
                        dialog.close();
                        if response == gtk::ResponseType::Accept {
                            perform(
                                install_state.clone(),
                                "install-appimage",
                                Some(version.clone()),
                                true,
                            );
                        }
                    });
                    dialog.present();
                }
            }
            Ok(_) => {
                if manual {
                    message(
                        &state,
                        "FILLR Updates",
                        "No newer compatible stable update is available.",
                    );
                }
            }
        }
        glib::ControlFlow::Break
    });
}
pub(super) fn connect(
    state: &Rc<RefCell<State>>,
    button: &gtk::Button,
    automatic: &gtk::CheckButton,
) {
    let manual = state.clone();
    button.connect_clicked(move |_| perform(manual.clone(), "check", None, true));
    let toggle_state = state.clone();
    automatic.connect_toggled(move |button| {
        if !button.is_sensitive() {
            return;
        }
        // One outstanding write prevents click-order inversions and makes a
        // persistence failure visible instead of silently lying about the setting.
        let desired = button.is_active();
        button.set_sensitive(false);
        let button = button.clone();
        let state = toggle_state.clone();
        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            let _ = tx.send(helper(if desired { "enable" } else { "disable" }, None));
        });
        glib::timeout_add_local(Duration::from_millis(150), move || {
            let result = match rx.try_recv() {
                Ok(result) => result,
                Err(mpsc::TryRecvError::Empty) => return glib::ControlFlow::Continue,
                Err(_) => Err("Update preference worker stopped".into()),
            };
            if let Err(error) = result {
                button.set_active(!desired);
                message(&state, "Could not save update preference", &error);
            }
            button.set_sensitive(true);
            glib::ControlFlow::Break
        });
    });
    perform(state.clone(), "check-auto", None, false);
    let periodic = state.clone();
    glib::timeout_add_local(Duration::from_secs(3600), move || {
        perform(periodic.clone(), "check-auto", None, false);
        glib::ControlFlow::Continue
    });
}
