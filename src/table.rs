use gtk::prelude::*;
use gtk::subclass::prelude::*;
use gtk::{gio, glib};

mod imp {
    use std::mem;

    use glib::error;
    use gtk::gio::{self, Cancellable};
    use gtk::CompositeTemplate;

    use super::*;
    use crate::row::Row;
    use crate::{tas_log, G_LOG_DOMAIN};

    #[derive(Debug, Default, CompositeTemplate)]
    #[template(resource = "/rs/bxt/TasLogReader/ui/table.ui")]
    pub struct Table {
        #[template_child]
        column_view: TemplateChild<gtk::ColumnView>,
        #[template_child]
        column_frame: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_time: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_ms: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_speed: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_vel_yaw: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_vert_speed: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_ground: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_duck_state: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_ladder_state: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_water_level: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_jump: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_duck: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_forward: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_side: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_up: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_yaw: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_pitch: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_health: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_armor: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_use: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_attack_1: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_attack_2: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_reload: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_client_state: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_shared_seed: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_pos_z: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_pos_x: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_pos_y: TemplateChild<gtk::ColumnViewColumn>,
        #[template_child]
        column_remainder: TemplateChild<gtk::ColumnViewColumn>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for Table {
        const NAME: &'static str = "TlrTable";
        type Type = super::Table;
        type ParentType = gtk::Widget;

        fn class_init(klass: &mut Self::Class) {
            Self::bind_template(klass);
        }

        fn instance_init(obj: &glib::subclass::InitializingObject<Self>) {
            obj.init_template();
        }
    }

    impl ObjectImpl for Table {
        fn constructed(&self, obj: &Self::Type) {
            self.parent_constructed(obj);

            const MAKE_LABEL: fn() -> gtk::Label = || {
                let label = gtk::Label::new(None);
                label.add_css_class("numeric");
                label
            };

            self.column_frame.set_factory(Some(&make_factory(
                || {
                    let label = MAKE_LABEL();
                    label.set_halign(gtk::Align::End);
                    label
                },
                |label, row: Row| {
                    label.set_text(&row.frame_number().to_string());
                },
            )));

            self.column_time.set_factory(Some(&make_factory(
                || {
                    let label = MAKE_LABEL();
                    label.add_css_class("not-important");
                    label
                },
                |label, row: Row| {
                    let text = (|| Some(format!("{:.3}", row.physics_frame().frame_time?)))();
                    label.set_text(text.as_deref().unwrap_or_default());
                },
            )));

            self.column_ms.set_factory(Some(&make_factory(
                || {
                    let label = MAKE_LABEL();
                    label.add_css_class("not-important");
                    label
                },
                |label, row: Row| {
                    let text = (|| Some(row.command_frame()?.msec.to_string()))();
                    label.set_text(text.as_deref().unwrap_or_default());
                },
            )));

            self.column_speed.set_factory(Some(&make_factory(
                || {
                    let label = MAKE_LABEL();
                    label.set_width_chars(9);
                    label
                },
                |label, row: Row| {
                    let text = (|| {
                        let vel = row.command_frame()?.post_pm_state?.velocity;
                        if vel[0] == 0. && vel[1] == 0. {
                            return None;
                        }

                        let speed = vel[0].hypot(vel[1]);
                        Some(format!("{:.3}", speed))
                    })();
                    label.set_text(text.as_deref().unwrap_or_default());
                },
            )));

            self.column_vel_yaw.set_factory(Some(&make_factory(
                || {
                    let label = MAKE_LABEL();
                    label.set_width_chars(8);
                    label
                },
                |label, row: Row| {
                    let text = (|| {
                        let vel = row.command_frame()?.post_pm_state?.velocity;
                        if vel[0] == 0. && vel[1] == 0. {
                            return None;
                        }

                        let angle = vel[1].atan2(vel[0]) * 180. / std::f32::consts::PI;
                        Some(format!("{:.3}", angle))
                    })();
                    label.set_text(text.as_deref().unwrap_or_default());
                },
            )));

            self.column_vert_speed
                .set_factory(Some(&make_factory_unbind(
                    MAKE_LABEL,
                    |label, row: Row| {
                        let text = (|| {
                            let vel = row.command_frame()?.post_pm_state?.velocity;
                            if vel[2] == 0. {
                                return None;
                            }

                            if vel[2] > 0. {
                                label.add_css_class("vert-speed-positive");
                            } else {
                                label.add_css_class("vert-speed-negative");
                            }

                            Some(format!("{:.1}", vel[2]))
                        })();

                        label.set_text(text.as_deref().unwrap_or_default());
                    },
                    |label| {
                        label.remove_css_class("vert-speed-negative");
                        label.remove_css_class("vert-speed-positive");
                    },
                )));

            self.column_ground.set_factory(Some(&make_factory_unbind(
                adw::Bin::new,
                |widget, row: Row| {
                    let state = match row
                        .command_frame()
                        .and_then(|frame| frame.post_pm_state.as_ref())
                    {
                        Some(value) => value,
                        None => return,
                    };

                    if state.on_ground {
                        widget.parent().unwrap().add_css_class("on-ground");
                    }
                },
                |widget| {
                    widget.parent().unwrap().remove_css_class("on-ground");
                },
            )));

            self.column_duck_state
                .set_factory(Some(&make_factory_unbind(
                    adw::Bin::new,
                    |widget, row: Row| {
                        let state = match row
                            .command_frame()
                            .and_then(|frame| frame.post_pm_state.as_ref())
                        {
                            Some(value) => value,
                            None => return,
                        };

                        match state.duck_state {
                            1 => widget.parent().unwrap().add_css_class("duck-state-1"),
                            2 => widget.parent().unwrap().add_css_class("duck-state-2"),
                            _ => (),
                        }
                    },
                    |widget| {
                        widget.parent().unwrap().remove_css_class("duck-state-1");
                        widget.parent().unwrap().remove_css_class("duck-state-2");
                    },
                )));

            self.column_ladder_state
                .set_factory(Some(&make_factory_unbind(
                    adw::Bin::new,
                    |widget, row: Row| {
                        let state = match row
                            .command_frame()
                            .and_then(|frame| frame.post_pm_state.as_ref())
                        {
                            Some(value) => value,
                            None => return,
                        };

                        if state.on_ladder {
                            widget.parent().unwrap().add_css_class("on-ladder");
                        }
                    },
                    |widget| {
                        widget.parent().unwrap().remove_css_class("on-ladder");
                    },
                )));

            self.column_water_level
                .set_factory(Some(&make_factory_unbind(
                    adw::Bin::new,
                    |widget, row: Row| {
                        let state = match row
                            .command_frame()
                            .and_then(|frame| frame.post_pm_state.as_ref())
                        {
                            Some(value) => value,
                            None => return,
                        };

                        match state.water_level {
                            1 => widget.parent().unwrap().add_css_class("water-level-1"),
                            2 => widget.parent().unwrap().add_css_class("water-level-2"),
                            _ => (),
                        }
                    },
                    |widget| {
                        widget.parent().unwrap().remove_css_class("water-level-1");
                        widget.parent().unwrap().remove_css_class("water-level-2");
                    },
                )));

            self.column_jump.set_factory(Some(&make_factory_unbind(
                adw::Bin::new,
                |widget, row: Row| {
                    let frame = match row.command_frame() {
                        Some(value) => value,
                        None => return,
                    };

                    if (frame.buttons & (1 << 1)) > 0 {
                        widget.parent().unwrap().add_css_class("jump-pressed");
                    }
                },
                |widget| {
                    widget.parent().unwrap().remove_css_class("jump-pressed");
                },
            )));

            self.column_duck.set_factory(Some(&make_factory_unbind(
                adw::Bin::new,
                |widget, row: Row| {
                    let frame = match row.command_frame() {
                        Some(value) => value,
                        None => return,
                    };

                    if (frame.buttons & (1 << 2)) > 0 {
                        widget.parent().unwrap().add_css_class("duck-pressed");
                    }
                },
                |widget| {
                    widget.parent().unwrap().remove_css_class("duck-pressed");
                },
            )));

            self.column_forward.set_factory(Some(&make_factory_unbind(
                MAKE_LABEL,
                |label, row: Row| {
                    let text = (|| {
                        let frame = row.command_frame()?;

                        match frame.fsu[0] {
                            x if x > 0. => {
                                label.parent().unwrap().add_css_class("forward-pressed");
                                Some("F")
                            }
                            x if x < 0. => {
                                label.parent().unwrap().add_css_class("back-pressed");
                                Some("B")
                            }
                            _ => None,
                        }
                    })();
                    label.set_text(text.unwrap_or_default());
                },
                |label| {
                    label.parent().unwrap().remove_css_class("forward-pressed");
                    label.parent().unwrap().remove_css_class("back-pressed");
                },
            )));

            self.column_side.set_factory(Some(&make_factory_unbind(
                MAKE_LABEL,
                |label, row: Row| {
                    let text = (|| {
                        let frame = row.command_frame()?;

                        match frame.fsu[1] {
                            x if x > 0. => {
                                label.parent().unwrap().add_css_class("right-pressed");
                                Some("R")
                            }
                            x if x < 0. => {
                                label.parent().unwrap().add_css_class("left-pressed");
                                Some("L")
                            }
                            _ => None,
                        }
                    })();
                    label.set_text(text.unwrap_or_default());
                },
                |label| {
                    label.parent().unwrap().remove_css_class("right-pressed");
                    label.parent().unwrap().remove_css_class("left-pressed");
                },
            )));

            self.column_up.set_factory(Some(&make_factory_unbind(
                MAKE_LABEL,
                |label, row: Row| {
                    let text = (|| {
                        let frame = row.command_frame()?;

                        match frame.fsu[2] {
                            x if x > 0. => {
                                label.parent().unwrap().add_css_class("up-pressed");
                                Some("U")
                            }
                            x if x < 0. => {
                                label.parent().unwrap().add_css_class("down-pressed");
                                Some("D")
                            }
                            _ => None,
                        }
                    })();
                    label.set_text(text.unwrap_or_default());
                },
                |label| {
                    label.parent().unwrap().remove_css_class("up-pressed");
                    label.parent().unwrap().remove_css_class("down-pressed");
                },
            )));

            self.column_yaw.set_factory(Some(&make_factory(
                || {
                    let label = MAKE_LABEL();
                    label.set_width_chars(8);
                    label
                },
                |label, row: Row| {
                    let text = (|| Some(format!("{:.3}", row.command_frame()?.view_angles[0])))();
                    label.set_text(text.as_deref().unwrap_or_default());
                },
            )));

            self.column_pitch.set_factory(Some(&make_factory(
                || {
                    let label = MAKE_LABEL();
                    label.set_width_chars(7);
                    label
                },
                |label, row: Row| {
                    let text = (|| Some(format!("{:.3}", row.command_frame()?.view_angles[1])))();
                    label.set_text(text.as_deref().unwrap_or_default());
                },
            )));

            self.column_health.set_factory(Some(&make_factory(
                || {
                    let label = MAKE_LABEL();
                    label.set_width_chars(5);
                    label
                },
                |label, row: Row| {
                    let text = (|| Some(format!("{:.0}", row.command_frame()?.health?)))();
                    label.set_text(text.as_deref().unwrap_or_default());
                },
            )));

            self.column_armor.set_factory(Some(&make_factory(
                || {
                    let label = MAKE_LABEL();
                    label.set_width_chars(5);
                    label
                },
                |label, row: Row| {
                    let text = (|| Some(format!("{:.1}", row.command_frame()?.armor?)))();
                    label.set_text(text.as_deref().unwrap_or_default());
                },
            )));

            self.column_use.set_factory(Some(&make_factory_unbind(
                adw::Bin::new,
                |widget, row: Row| {
                    let frame = match row.command_frame() {
                        Some(value) => value,
                        None => return,
                    };

                    if (frame.buttons & (1 << 5)) > 0 {
                        widget.parent().unwrap().add_css_class("use-pressed");
                    }
                },
                |widget| {
                    widget.parent().unwrap().remove_css_class("use-pressed");
                },
            )));

            self.column_attack_1.set_factory(Some(&make_factory_unbind(
                adw::Bin::new,
                |widget, row: Row| {
                    let frame = match row.command_frame() {
                        Some(value) => value,
                        None => return,
                    };

                    if (frame.buttons & (1 << 0)) > 0 {
                        widget.parent().unwrap().add_css_class("attack-1-pressed");
                    }
                },
                |widget| {
                    widget
                        .parent()
                        .unwrap()
                        .remove_css_class("attack-1-pressed");
                },
            )));

            self.column_attack_2.set_factory(Some(&make_factory_unbind(
                adw::Bin::new,
                |widget, row: Row| {
                    let frame = match row.command_frame() {
                        Some(value) => value,
                        None => return,
                    };

                    if (frame.buttons & (1 << 11)) > 0 {
                        widget.parent().unwrap().add_css_class("attack-2-pressed");
                    }
                },
                |widget| {
                    widget
                        .parent()
                        .unwrap()
                        .remove_css_class("attack-2-pressed");
                },
            )));

            self.column_reload.set_factory(Some(&make_factory_unbind(
                adw::Bin::new,
                |widget, row: Row| {
                    let frame = match row.command_frame() {
                        Some(value) => value,
                        None => return,
                    };

                    if (frame.buttons & (1 << 13)) > 0 {
                        widget.parent().unwrap().add_css_class("reload-pressed");
                    }
                },
                |widget| {
                    widget.parent().unwrap().remove_css_class("reload-pressed");
                },
            )));

            self.column_client_state
                .set_factory(Some(&make_factory_unbind(
                    || {
                        let label = MAKE_LABEL();
                        label.add_css_class("not-important");
                        label
                    },
                    |label, row: Row| {
                        let state = row.physics_frame().client_state;

                        label.set_text(&state.to_string());

                        if state != 5 {
                            label.add_css_class("client-state-not-5");
                        }
                    },
                    |label| {
                        label.remove_css_class("client-state-not-5");
                    },
                )));

            self.column_shared_seed.set_factory(Some(&make_factory(
                || {
                    let label = MAKE_LABEL();
                    label.add_css_class("not-important");
                    label
                },
                |label, row: Row| {
                    let text = (|| Some(row.command_frame()?.shared_seed.to_string()))();
                    label.set_text(text.as_deref().unwrap_or_default());
                },
            )));

            self.column_pos_z.set_factory(Some(&make_factory(
                || {
                    let label = MAKE_LABEL();
                    label.set_width_chars(9);
                    label
                },
                |label, row: Row| {
                    let text = (|| {
                        Some(format!(
                            "{:.3}",
                            row.command_frame()?.post_pm_state?.position[2]
                        ))
                    })();
                    label.set_text(text.as_deref().unwrap_or_default());
                },
            )));

            self.column_pos_x.set_factory(Some(&make_factory(
                || {
                    let label = MAKE_LABEL();
                    label.set_width_chars(9);
                    label
                },
                |label, row: Row| {
                    let text = (|| {
                        Some(format!(
                            "{:.3}",
                            row.command_frame()?.post_pm_state?.position[0]
                        ))
                    })();
                    label.set_text(text.as_deref().unwrap_or_default());
                },
            )));

            self.column_pos_y.set_factory(Some(&make_factory(
                || {
                    let label = MAKE_LABEL();
                    label.set_width_chars(9);
                    label
                },
                |label, row: Row| {
                    let text = (|| {
                        Some(format!(
                            "{:.3}",
                            row.command_frame()?.post_pm_state?.position[1]
                        ))
                    })();
                    label.set_text(text.as_deref().unwrap_or_default());
                },
            )));

            self.column_remainder.set_factory(Some(&make_factory(
                || {
                    let label = MAKE_LABEL();
                    label.set_width_chars(7);
                    label.add_css_class("not-important");
                    label
                },
                |label, row: Row| {
                    let text = (|| {
                        Some(format!(
                            "{:.2e}",
                            row.command_frame()?.frame_time_remainder?
                        ))
                    })();
                    label.set_text(text.as_deref().unwrap_or_default());
                },
            )));
        }

        fn dispose(&self, obj: &Self::Type) {
            while let Some(child) = obj.first_child() {
                child.unparent();
            }
        }
    }

    impl WidgetImpl for Table {}

    impl Table {
        pub fn open(&self, file: &gio::File) {
            match file.load_contents(None::<&Cancellable>) {
                Ok((contents, _)) => {
                    fn from_slice_lenient<'a, T: serde::Deserialize<'a>>(
                        v: &'a [u8],
                    ) -> Result<T, serde_json::Error> {
                        let mut cur = std::io::Cursor::new(v);
                        let mut de =
                            serde_json::Deserializer::new(serde_json::de::IoRead::new(&mut cur));
                        serde::Deserialize::deserialize(&mut de)
                    }

                    match from_slice_lenient::<tas_log::Log>(&contents) {
                        Ok(mut log) => {
                            let model = gio::ListStore::new(Row::static_type());

                            let mut number = 0;
                            for mut physics_frame in log.physics_frames.drain(..) {
                                if physics_frame.command_frames.is_empty() {
                                    number += 1;
                                    model.append(&Row::new(number, physics_frame, None));
                                    continue;
                                }

                                let mut command_frames =
                                    mem::take(&mut physics_frame.command_frames);
                                for command_frame in command_frames.drain(..) {
                                    number += 1;
                                    model.append(&Row::new(
                                        number,
                                        physics_frame.clone(),
                                        Some(command_frame),
                                    ));
                                }
                            }

                            self.column_view
                                .set_model(Some(&gtk::MultiSelection::new(Some(&model))));
                        }
                        Err(err) => error!("{:?}", err),
                    }
                }
                Err(err) => error!("{:?}", err),
            }
        }
    }
}

fn make_factory<Widget, T>(
    setup: impl Fn() -> Widget + 'static,
    bind: impl Fn(Widget, T) + 'static,
) -> gtk::SignalListItemFactory
where
    Widget: glib::IsA<gtk::Widget>,
    T: glib::IsA<glib::Object>,
{
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(move |_factory, item| {
        let widget = setup();
        item.set_child(Some(&widget));
    });
    factory.connect_bind(move |_factory, item| {
        let widget: Widget = item.child().unwrap().downcast().unwrap();
        let row: T = item.item().unwrap().downcast().unwrap();
        bind(widget, row);
    });
    factory
}

fn make_factory_unbind<Widget, T>(
    setup: impl Fn() -> Widget + 'static,
    bind: impl Fn(Widget, T) + 'static,
    unbind: impl Fn(Widget) + 'static,
) -> gtk::SignalListItemFactory
where
    Widget: glib::IsA<gtk::Widget>,
    T: glib::IsA<glib::Object>,
{
    let factory = make_factory(setup, bind);
    factory.connect_unbind(move |_factory, item| {
        let widget: Widget = item.child().unwrap().downcast().unwrap();
        unbind(widget);
    });
    factory
}

glib::wrapper! {
    pub struct Table(ObjectSubclass<imp::Table>)
        @extends gtk::Widget;
}

impl Table {
    pub fn open(&self, file: &gio::File) {
        self.imp().open(file)
    }
}
