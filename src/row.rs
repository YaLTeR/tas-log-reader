use glib::subclass::types::ObjectSubclassExt;
use gtk::glib;

use crate::tas_log::{CommandFrame, PhysicsFrame};

mod imp {
    use std::cell::Cell;

    use glib::subclass::prelude::*;
    use once_cell::unsync::OnceCell;

    use super::*;
    use crate::tas_log::PhysicsFrame;

    #[derive(Debug, Default)]
    pub struct Row {
        pub frame_number: Cell<usize>,
        pub physics_frame: OnceCell<PhysicsFrame>,
        pub command_frame: OnceCell<Option<CommandFrame>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for Row {
        const NAME: &'static str = "TlrRow";
        type Type = super::Row;
        type ParentType = glib::Object;
    }

    impl ObjectImpl for Row {}
}

glib::wrapper! {
    pub struct Row(ObjectSubclass<imp::Row>);
}

impl Row {
    pub fn new(
        frame_number: usize,
        physics_frame: PhysicsFrame,
        command_frame: Option<CommandFrame>,
    ) -> Self {
        let self_ = glib::Object::new(&[]).unwrap();

        let priv_ = imp::Row::from_instance(&self_);
        priv_.frame_number.set(frame_number);
        priv_.physics_frame.set(physics_frame).unwrap();
        priv_.command_frame.set(command_frame).unwrap();

        self_
    }

    pub fn frame_number(&self) -> usize {
        imp::Row::from_instance(self).frame_number.get()
    }

    pub fn physics_frame(&self) -> &PhysicsFrame {
        imp::Row::from_instance(self).physics_frame.get().unwrap()
    }

    pub fn command_frame(&self) -> Option<&CommandFrame> {
        imp::Row::from_instance(self)
            .command_frame
            .get()
            .unwrap()
            .as_ref()
    }
}
