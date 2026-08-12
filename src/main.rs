mod application;
#[rustfmt::skip]
mod config;
mod row;
mod table;
mod tas_log;
mod window;

use std::env;

use application::Application;
use gettextrs::*;
use gtk::prelude::*;
use gtk::{gio, glib};
use tracing::{info, warn};

fn main() {
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::DEBUG)
        .init();

    info!("TAS Log Reader version {}", config::VERSION);

    setlocale(LocaleCategory::LcAll, "");
    if let Err(err) = bindtextdomain("tas-log-reader", config::LOCALEDIR) {
        warn!("Error in bindtextdomain(): {}", err);
    }
    if let Err(err) = bind_textdomain_codeset("tas-log-reader", "UTF-8") {
        warn!("Error in bind_textdomain_codeset(): {}", err);
    }
    if let Err(err) = textdomain("tas-log-reader") {
        warn!("Error in textdomain(): {}", err);
    }

    glib::set_application_name(&format!(
        "{}{}",
        gettext("TAS Log Reader"),
        config::NAME_SUFFIX
    ));

    let res = match env::var("MESON_DEVENV") {
        Err(_) => {
            gio::Resource::load(config::RESOURCES_FILE).expect("could not load the gresource file")
        }
        Ok(_) => {
            let mut resource_path = env::current_exe().expect("unable to get executable path");
            resource_path.pop();
            resource_path.pop();
            resource_path.push("data");
            resource_path.push("resources");
            resource_path.push("resources.gresource");
            gio::Resource::load(&resource_path)
                .expect("unable to load resources.gresource from build dir")
        }
    };
    gio::resources_register(&res);

    Application::new().run();
}
