use gtk::prelude::*;
use gtk::subclass::prelude::*;
use gtk::{gio, glib};

use crate::application::Application;
use crate::config::{APP_ID, PROFILE};

mod imp {
    use gettextrs::gettext;
    use gtk::{CompositeTemplate, ResponseType};

    use super::*;
    use crate::table::Table;

    #[derive(Debug, CompositeTemplate)]
    #[template(resource = "/rs/bxt/TasLogReader/ui/window.ui")]
    pub struct ApplicationWindow {
        #[template_child]
        pub headerbar: TemplateChild<gtk::HeaderBar>,
        #[template_child]
        pub button_open: TemplateChild<gtk::Button>,
        #[template_child]
        pub table: TemplateChild<Table>,

        pub settings: gio::Settings,
    }

    impl Default for ApplicationWindow {
        fn default() -> Self {
            Self {
                headerbar: TemplateChild::default(),
                button_open: TemplateChild::default(),
                table: TemplateChild::default(),
                settings: gio::Settings::new(APP_ID),
            }
        }
    }

    #[glib::object_subclass]
    impl ObjectSubclass for ApplicationWindow {
        const NAME: &'static str = "TlrApplicationWindow";
        type Type = super::ApplicationWindow;
        type ParentType = gtk::ApplicationWindow;

        fn class_init(klass: &mut Self::Class) {
            Self::bind_template(klass);
        }

        // You must call `Widget`'s `init_template()` within `instance_init()`.
        fn instance_init(obj: &glib::subclass::InitializingObject<Self>) {
            obj.init_template();
        }
    }

    impl ObjectImpl for ApplicationWindow {
        fn constructed(&self, self_: &Self::Type) {
            self.parent_constructed(self_);

            // Devel Profile
            if PROFILE == "Devel" {
                self_.add_css_class("devel");
            }

            // Load latest window state
            self_.load_window_size();

            self.button_open.connect_clicked({
                let self_ = self_.downgrade();
                move |_| {
                    let self_ = self_.upgrade().unwrap();

                    let file_chooser = gtk::FileChooserNativeBuilder::new()
                        .transient_for(&self_)
                        .action(gtk::FileChooserAction::Open)
                        // Translators: file chooser dialog title.
                        .title(&gettext("Open TAS log"))
                        .transient_for(&self_)
                        .modal(true)
                        .build();

                    glib::MainContext::default().spawn_local(async move {
                        if file_chooser.run_future().await != ResponseType::Accept {
                            return;
                        }

                        let file = file_chooser.file().unwrap();
                        self_.open(file);
                    });
                }
            });
        }
    }

    impl WidgetImpl for ApplicationWindow {}
    impl WindowImpl for ApplicationWindow {
        // Save window state on delete event
        fn close_request(&self, window: &Self::Type) -> gtk::Inhibit {
            if let Err(err) = window.save_window_size() {
                log::warn!("Failed to save window state, {}", &err);
            }

            // Pass close request on to the parent
            self.parent_close_request(window)
        }
    }

    impl ApplicationWindowImpl for ApplicationWindow {}

    impl ApplicationWindow {
        pub fn open(&self, file: gio::File) {
            self.table.open(file);
        }
    }
}

glib::wrapper! {
    pub struct ApplicationWindow(ObjectSubclass<imp::ApplicationWindow>)
        @extends gtk::Widget, gtk::Window, gtk::ApplicationWindow,
        @implements gio::ActionMap, gio::ActionGroup;
}

impl ApplicationWindow {
    pub fn new(app: &Application) -> Self {
        glib::Object::new(&[("application", app)]).expect("Failed to create ApplicationWindow")
    }

    fn open(&self, file: gio::File) {
        imp::ApplicationWindow::from_instance(self).open(file)
    }

    fn save_window_size(&self) -> Result<(), glib::BoolError> {
        let self_ = imp::ApplicationWindow::from_instance(self);

        let (width, height) = self.default_size();

        self_.settings.set_int("window-width", width)?;
        self_.settings.set_int("window-height", height)?;

        self_
            .settings
            .set_boolean("is-maximized", self.is_maximized())?;

        Ok(())
    }

    fn load_window_size(&self) {
        let self_ = imp::ApplicationWindow::from_instance(self);

        let width = self_.settings.int("window-width");
        let height = self_.settings.int("window-height");
        let is_maximized = self_.settings.boolean("is-maximized");

        self.set_default_size(width, height);

        if is_maximized {
            self.maximize();
        }
    }
}
