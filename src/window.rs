use gettextrs::gettext;
use glib::clone;
use gtk::prelude::*;
use gtk::subclass::prelude::*;
use gtk::{gio, glib};
use tracing::instrument;

use crate::config;

mod imp {
    use futures_util::join;
    use gettextrs::{gettext, ngettext};
    use gtk::glib::closure;
    use gtk::CompositeTemplate;
    use tracing::{info_span, warn, Instrument};

    use super::*;
    use crate::table::Table;

    #[derive(Debug, Default, CompositeTemplate)]
    #[template(resource = "/rs/bxt/TasLogReader/ui/window.ui")]
    pub struct Window {
        #[template_child]
        pub title: TemplateChild<adw::WindowTitle>,
        #[template_child]
        pub label_frames_selected: TemplateChild<gtk::Label>,
        #[template_child]
        pub table: TemplateChild<Table>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for Window {
        const NAME: &'static str = "TlrWindow";
        type Type = super::Window;
        type ParentType = gtk::ApplicationWindow;

        fn class_init(klass: &mut Self::Class) {
            Self::bind_template(klass);
            Self::Type::bind_template_callbacks(klass);

            klass.install_action("win.open", None, |obj, _, _| obj.on_open_clicked());

            klass.install_action("win.reload", None, |obj, _, _| {
                glib::MainContext::default().spawn_local(clone!(@weak obj => async move {
                    obj.imp().table.reload().await;
                }));
            });

            klass.install_action("win.about", None, |window, _, _| {
                gtk::AboutDialog::builder()
                    .transient_for(window)
                    .modal(true)
                    .logo_icon_name(config::APP_ID)
                    .version(config::VERSION)
                    .license_type(gtk::License::Gpl30)
                    .authors(vec!["Ivan Molodetskikh".to_owned()])
                    .website("https://github.com/YaLTeR/tas-log-reader")
                    // Translators: shown in the About dialog, put your name here.
                    .translator_credits(&gettext("translator-credits"))
                    .build()
                    .show();
            });
        }

        fn instance_init(obj: &glib::subclass::InitializingObject<Self>) {
            obj.init_template();
        }
    }

    impl ObjectImpl for Window {
        fn constructed(&self, obj: &Self::Type) {
            self.parent_constructed(obj);

            if config::PROFILE == "Devel" {
                obj.add_css_class("devel");
            }

            obj.load_window_size();

            self.table
                .property_expression("frames-selected")
                .chain_closure::<String>(closure!(
                    |_: Option<glib::Object>, frames_selected: u32| {
                        ngettext!(
                            "{} fr. sel.",
                            "{} fr. sel.",
                            frames_selected,
                            frames_selected
                        )
                    }
                ))
                .bind(&*self.label_frames_selected, "label", None::<&Table>);
        }
    }

    impl WidgetImpl for Window {}

    impl WindowImpl for Window {
        fn close_request(&self, window: &Self::Type) -> gtk::Inhibit {
            if let Err(err) = window.save_window_size() {
                warn!("failed to save window state: {err:?}");
            }

            self.parent_close_request(window)
        }
    }

    impl ApplicationWindowImpl for Window {}

    impl Window {
        #[instrument(skip_all, fields(file = ?file.uri()))]
        pub async fn open(&self, file: &gio::File) {
            let table_open = self.table.open(file.clone());

            let get_display_name = async {
                let info = file
                    .query_info_future(
                        "standard::display-name",
                        gio::FileQueryInfoFlags::NONE,
                        glib::PRIORITY_DEFAULT,
                    )
                    .await;

                let name = match info {
                    Ok(info) => info.display_name(),
                    Err(err) => {
                        warn!("error retrieving file display name: {err:?}");
                        "".into()
                    }
                };

                name
            }
            .instrument(info_span!("get_display_name"));

            let name = join!(table_open, get_display_name).1;

            // Only set the name after the table is updated too.
            self.title.set_subtitle(&name);
        }
    }
}

glib::wrapper! {
    pub struct Window(ObjectSubclass<imp::Window>)
        @extends gtk::Widget, gtk::Window, gtk::ApplicationWindow,
        @implements gio::ActionMap, gio::ActionGroup;
}

#[gtk::template_callbacks]
impl Window {
    pub fn new(app: &impl IsA<gtk::Application>) -> Self {
        glib::Object::new(&[("application", app)]).unwrap()
    }

    pub fn open(&self, file: gio::File) {
        glib::MainContext::default().spawn_local(clone!(@weak self as obj => async move {
            obj.imp().open(&file).await;
        }));
    }

    #[template_callback]
    fn on_open_clicked(&self) {
        let file_chooser = gtk::FileChooserNative::builder()
            .transient_for(self)
            .modal(true)
            .action(gtk::FileChooserAction::Open)
            // Translators: file chooser dialog title.
            .title(&gettext("Open TAS log"))
            .build();

        let filter = gtk::FileFilter::new();
        filter.set_name(Some(&gettext("TAS log files")));
        filter.add_suffix("log");
        file_chooser.add_filter(&filter);

        let filter = gtk::FileFilter::new();
        filter.set_name(Some(&gettext("All files")));
        filter.add_pattern("*");
        file_chooser.add_filter(&filter);

        glib::MainContext::default().spawn_local(clone!(@weak self as obj => async move {
            if file_chooser.run_future().await != gtk::ResponseType::Accept {
                return;
            }

            if let Some(file) = file_chooser.file() {
                obj.imp().open(&file).await;
            }
        }));
    }

    fn save_window_size(&self) -> Result<(), glib::BoolError> {
        let (width, height) = self.default_size();

        let settings = gio::Settings::new(config::APP_ID);
        settings.set_int("window-width", width)?;
        settings.set_int("window-height", height)?;
        settings.set_boolean("is-maximized", self.is_maximized())?;

        Ok(())
    }

    fn load_window_size(&self) {
        let settings = gio::Settings::new(config::APP_ID);
        let width = settings.int("window-width");
        let height = settings.int("window-height");
        let is_maximized = settings.boolean("is-maximized");

        self.set_default_size(width, height);

        if is_maximized {
            self.maximize();
        }
    }
}
