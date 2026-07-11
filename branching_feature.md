We need to implement a branching feature along with a special web gui
This is separate from our normal workflow so we will take it to the browser
As the task is a little more complex

Normal mass message flow

Follow up1 -> Follow up2 -> Follow up3 -> PPV

The point is, follow ups should be able to answer the most common expected response

But we run into a problem of having multiple common answers that all need to be covered

The idea is to have a web editor that can the convo flows fu1->resp1->fu2->resp2
And that the gui can spawn a new thread with alternate routes fu1->resp3->fuALT->resp4
These branches should be able to merge back into a main branch

This is just a visual tool, its output is a !mma mass message in a new format

!mma My mass message

Fu1:
Fu2:
Fu3:

[altbranch1]

altbranch1
altbranch2
altbranch3

[altbranch2]

altbranch2
altbranch3

This should work as multiple threads that can merge back into each other or split off
Kind of like git?

If you disapprove of the format make up a new one
We are just implementing the webgui now
How to parse this and turn it into hotkey is part 2 of the problem

This is a generelization of the Or-Or mass problem
This one woudl just have 2 full branches
Instead of a few partial ones
