use std::collections::VecDeque;

/// The answers a fake gives, in order.
///
/// A fake with no answer left for a call panics. A stub with no arm for a call
/// the code makes returns nothing, the caller errors, and the guard under test
/// skips in silence. The panic makes that visible.
#[derive(Debug, Clone)]
pub struct Script<T: Clone> {
    queue: VecDeque<T>,
    repeat: Option<T>,
}

impl<T: Clone> Script<T> {
    /// No answers. Any call panics.
    #[must_use]
    pub fn none() -> Self {
        Self { queue: VecDeque::new(), repeat: None }
    }

    /// The same answer for every call.
    #[must_use]
    pub fn always(value: T) -> Self {
        Self { queue: VecDeque::new(), repeat: Some(value) }
    }

    /// One answer per call, in order. The call after the last one panics.
    #[must_use]
    pub fn sequence(values: impl IntoIterator<Item = T>) -> Self {
        Self { queue: values.into_iter().collect(), repeat: None }
    }

    /// The answer for the next call to `call`.
    ///
    /// # Panics
    ///
    /// Panics when the script holds no answer, naming `call`.
    pub fn next(&mut self, call: &str) -> T {
        if let Some(value) = self.queue.pop_front() {
            return value;
        }
        match &self.repeat {
            Some(value) => value.clone(),
            None => panic!(
                "unscripted call: no answer left for {call}; script one before the code under test runs"
            ),
        }
    }
}

impl<T: Clone> Default for Script<T> {
    fn default() -> Self {
        Self::none()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sequence_answers_in_order() {
        let mut script = Script::sequence([1, 2, 3]);
        assert_eq!([script.next("x"), script.next("x"), script.next("x")], [1, 2, 3]);
    }

    #[test]
    fn always_repeats_forever() {
        let mut script = Script::always("same");
        assert_eq!(
            (script.next("x"), script.next("x"), script.next("x")),
            ("same", "same", "same")
        );
    }

    #[test]
    #[should_panic(expected = "unscripted call: no answer left for login")]
    fn an_empty_script_panics_and_names_the_call() {
        let mut script: Script<u8> = Script::none();
        script.next("login");
    }

    #[test]
    #[should_panic(expected = "unscripted call")]
    fn a_sequence_panics_after_its_last_answer() {
        let mut script = Script::sequence([1]);
        script.next("x");
        script.next("x");
    }
}
