use thiserror::Error;

/// The error for building a [`NonEmpty`] from nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[error("the list is empty, and this one must hold at least one item")]
pub struct Empty;

/// A list with at least one item.
///
/// The check happens once, at construction. After that nothing downstream has
/// to ask whether the list is empty, and a read that came back empty cannot be
/// mistaken for an answer.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct NonEmpty<T>(Vec<T>);

impl<T> NonEmpty<T> {
    /// A list of one item followed by `rest`.
    pub fn new(first: T, rest: impl IntoIterator<Item = T>) -> Self {
        let mut items = vec![first];
        items.extend(rest);
        Self(items)
    }

    /// Wraps a vector, or says it was empty.
    pub fn from_vec(items: Vec<T>) -> Result<Self, Empty> {
        if items.is_empty() { Err(Empty) } else { Ok(Self(items)) }
    }

    /// The first item.
    #[must_use]
    pub fn first(&self) -> &T {
        &self.0[0]
    }

    /// The last item.
    #[must_use]
    pub fn last(&self) -> &T {
        &self.0[self.0.len() - 1]
    }

    /// How many items there are; always at least one.
    #[allow(
        clippy::len_without_is_empty,
        reason = "a NonEmpty is never empty, so is_empty would always say false"
    )]
    #[must_use]
    pub fn len(&self) -> usize {
        self.0.len()
    }

    /// The items as a slice.
    #[must_use]
    pub fn as_slice(&self) -> &[T] {
        &self.0
    }

    /// Iterates over the items.
    pub fn iter(&self) -> std::slice::Iter<'_, T> {
        self.0.iter()
    }

    /// Adds an item at the end.
    pub fn push(&mut self, item: T) {
        self.0.push(item);
    }

    /// Gives the items back as a plain vector.
    #[must_use]
    pub fn into_vec(self) -> Vec<T> {
        self.0
    }
}

impl<T> TryFrom<Vec<T>> for NonEmpty<T> {
    type Error = Empty;

    fn try_from(items: Vec<T>) -> Result<Self, Empty> {
        Self::from_vec(items)
    }
}

impl<T> IntoIterator for NonEmpty<T> {
    type Item = T;
    type IntoIter = std::vec::IntoIter<T>;

    fn into_iter(self) -> Self::IntoIter {
        self.0.into_iter()
    }
}

impl<'a, T> IntoIterator for &'a NonEmpty<T> {
    type Item = &'a T;
    type IntoIter = std::slice::Iter<'a, T>;

    fn into_iter(self) -> Self::IntoIter {
        self.0.iter()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_vec_refuses_an_empty_vector() {
        assert_eq!(NonEmpty::<u8>::from_vec(Vec::new()), Err(Empty));
    }

    #[test]
    fn from_vec_keeps_order_and_length() {
        let list = NonEmpty::from_vec(vec![1, 2, 3]).unwrap();
        assert_eq!(list.as_slice(), &[1, 2, 3]);
        assert_eq!(list.len(), 3);
    }

    #[test]
    fn new_puts_the_first_item_first() {
        let list = NonEmpty::new("git", ["status", "-s"]);
        assert_eq!(list.first(), &"git");
        assert_eq!(list.last(), &"-s");
        assert_eq!(list.len(), 3);
    }

    #[test]
    fn a_single_item_is_first_and_last() {
        let list = NonEmpty::new(5, []);
        assert_eq!((list.first(), list.last(), list.len()), (&5, &5, 1));
    }

    #[test]
    fn push_and_into_vec_round_trip() {
        let mut list = NonEmpty::new(1, []);
        list.push(2);
        assert_eq!(list.into_vec(), vec![1, 2]);
    }

    #[test]
    fn try_from_follows_from_vec() {
        assert_eq!(NonEmpty::<u8>::try_from(Vec::new()), Err(Empty));
        assert_eq!(NonEmpty::try_from(vec![8]).unwrap().into_vec(), vec![8]);
    }

    #[test]
    fn iteration_by_reference_and_by_value_visits_every_item() {
        let list = NonEmpty::new(1, [2, 3]);
        assert_eq!((&list).into_iter().sum::<i32>(), 6);
        assert_eq!(list.iter().count(), 3);
        assert_eq!(list.into_iter().collect::<Vec<_>>(), vec![1, 2, 3]);
    }
}
