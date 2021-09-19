mod application;
#[rustfmt::skip]
mod config;
mod row;
mod table;
mod tas_log;
mod window;

use application::Application;
use config::{GETTEXT_PACKAGE, G_LOG_DOMAIN, LOCALEDIR, RESOURCES_FILE};
use gettextrs::{gettext, LocaleCategory};
use glib::{info, GlibLogger, GlibLoggerDomain, GlibLoggerFormat};
use gtk::{gio, glib};

fn main() {
    static GLIB_LOGGER: GlibLogger =
        GlibLogger::new(GlibLoggerFormat::LineAndFile, GlibLoggerDomain::CrateTarget);

    let _ = log::set_logger(&GLIB_LOGGER);
    log::set_max_level(log::LevelFilter::Debug);

    info!("TAS Log Reader version {}", config::VERSION);

    gettextrs::setlocale(LocaleCategory::LcAll, "");
    gettextrs::bindtextdomain(GETTEXT_PACKAGE, LOCALEDIR).expect("Unable to bind the text domain");
    gettextrs::textdomain(GETTEXT_PACKAGE).expect("Unable to switch to the text domain");

    glib::set_application_name(&gettext("TAS Log Reader"));

    gtk::init().expect("Unable to start GTK4");

    let res = gio::Resource::load(RESOURCES_FILE).expect("Could not load gresource file");
    gio::resources_register(&res);

    let app = Application::new();
    app.run();
}
