use gtk::prelude::*;
use gtk::{gio, glib};

use crate::config;
use crate::window::Window;

mod imp {
    use adw::subclass::prelude::*;
    use glib::clone;
    use gtk::subclass::prelude::*;
    use tracing::debug;

    use super::*;

    #[derive(Debug, Default)]
    pub struct Application {}

    #[glib::object_subclass]
    impl ObjectSubclass for Application {
        const NAME: &'static str = "TlrApplication";
        type Type = super::Application;
        type ParentType = adw::Application;
    }

    impl ObjectImpl for Application {}

    impl ApplicationImpl for Application {
        fn activate(&self, obj: &Self::Type) {
            debug!("activate");
            self.parent_activate(obj);
            obj.open_new_window();
        }

        fn open(&self, obj: &Self::Type, files: &[gio::File], _hint: &str) {
            debug!(files = ?files.iter().map(|x| x.uri()).collect::<Vec<_>>(), "open");

            for file in files {
                let window = obj.open_new_window();
                window.open(file.clone());
            }
        }

        fn startup(&self, obj: &Self::Type) {
            debug!("startup");

            self.parent_startup(obj);

            let action = gio::SimpleAction::new("quit", None);
            action.connect_activate(clone!(@weak obj => move |_, _| obj.quit()));
            obj.add_action(&action);
            obj.set_accels_for_action("app.quit", &["<primary>q"]);

            let action = gio::SimpleAction::new("new-window", None);
            action.connect_activate(clone!(@weak obj => move |_, _| { obj.open_new_window(); }));
            obj.add_action(&action);
            obj.set_accels_for_action("app.new-window", &["<primary>n"]);
        }
    }

    impl GtkApplicationImpl for Application {}
    impl AdwApplicationImpl for Application {}
}

glib::wrapper! {
    pub struct Application(ObjectSubclass<imp::Application>)
        @extends gio::Application, gtk::Application, adw::Application,
        @implements gio::ActionMap, gio::ActionGroup;
}

impl Application {
    pub fn new() -> Self {
        glib::Object::new(&[
            ("application-id", &config::APP_ID),
            ("flags", &gio::ApplicationFlags::HANDLES_OPEN),
            ("resource-base-path", &"/rs/bxt/TasLogReader/"),
        ])
        .unwrap()
    }

    pub fn create_new_window(&self) -> Window {
        let window = Window::new(self);

        // Put it in a new window group so modal dialogs don't block other windows.
        let group = gtk::WindowGroup::new();
        group.add_window(&window);

        window
    }

    pub fn open_new_window(&self) -> Window {
        let window = self.create_new_window();

        window.present();

        window
    }
}

impl Default for Application {
    fn default() -> Self {
        Self::new()
    }
}
