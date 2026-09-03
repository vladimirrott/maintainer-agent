# Task: file what you found, and place what is already filed

The tracker is the project's memory. A finding that lives only in a run report
is a finding nobody else can act on.

## File what a run actually found

One issue per finding, each with:

- the command that produced it and the output, quoted, not summarised;
- the file and line it lives at, resolved against the current tree;
- what breaks if nobody fixes it, in one sentence;
- what "done" looks like, concretely enough that somebody else can tell.

Never file a suspicion. If you could not reproduce it, say so in the run report
and file nothing. An issue that turns out to be noise costs a maintainer more
than the finding was worth, and a tracker full of them is how projects stop
being read.

## Place what is filed

For each unassigned issue, ask who has demonstrated the skill it needs, in this
repository, in the last month. Offer it to that person by name, in one comment,
with the two or three pointers that would have taken them an hour to find.

One open offer per person. Somebody with an unanswered offer gets nothing new;
a second one reads as pressure and it is how volunteers quietly leave.

## Answer the question the documentation should have answered

When you answer a question that a document should have covered, name that
document and file the gap as its own issue. Most maintainer time goes there,
and it is the part that compounds.
