mod application;
#[rustfmt::skip]
mod config;
mod row;
mod table;
mod tas_log;
mod window;

use application::Application;
use gettextrs::*;
use glib::{info, warn, GlibLogger, GlibLoggerDomain, GlibLoggerFormat};
use gtk::prelude::*;
use gtk::{gio, glib};

const G_LOG_DOMAIN: &str = "TasLogReader";

fn main() {
    static GLIB_LOGGER: GlibLogger =
        GlibLogger::new(GlibLoggerFormat::LineAndFile, GlibLoggerDomain::CrateTarget);

    let _ = log::set_logger(&GLIB_LOGGER);
    log::set_max_level(log::LevelFilter::Debug);

    info!("TAS Log Reader version {}", config::VERSION);

    setlocale(LocaleCategory::LcAll, "");
    if let Err(err) = bindtextdomain(config::GETTEXT_PACKAGE, config::LOCALEDIR) {
        warn!("Error in bindtextdomain(): {}", err);
    }
    if let Err(err) = bind_textdomain_codeset(config::GETTEXT_PACKAGE, "UTF-8") {
        warn!("Error in bind_textdomain_codeset(): {}", err);
    }
    if let Err(err) = textdomain(config::GETTEXT_PACKAGE) {
        warn!("Error in textdomain(): {}", err);
    }

    glib::set_application_name(&format!(
        "{}{}",
        gettext("TAS Log Reader"),
        config::NAME_SUFFIX
    ));

    let res = gio::Resource::load(config::RESOURCES_FILE).expect("Could not load gresource file");
    gio::resources_register(&res);

    std::process::exit(Application::new().run());
}
