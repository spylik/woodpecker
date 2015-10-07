Woodpecker with Gun
======

Woody Woodpecker is an anthropomorphic animated woodpecker who appeared in theatrical short films produced by the Walter Lantz animation studio and distributed by Universal Pictures. Though not the first of the screwball characters that became popular in the 1940s, Woody is one of the most indicative of the type. (c) [wikipedia](https://en.wikipedia.org/wiki/Woody_Woodpecker)

Our **woodpecker** also can peck, but he **peck http servers until got answer that will satisfy him**.

Woodpecker uses [Gun](https://github.com/ninenines/gun)

Features
-----

 *  Ban protection: woodpecker can use few behaviour to prevent server-side ban:
 - Limit requests per period.  New requests will wait in the queue and fire when it should be safe;
 - Time degradation.  Every unsucceed request returns to the queue with delay * n of fail requests. 

 *  Queue requests with different priority;
- Low proprity:
Request fire one by one.

- Normal priority:
One by one but on top of low.

- High priority:
Always the top of queue.

- Urgent priority:
Don't care about queue. Fire immediately!

 *  Success/trigger trigger.

 *  HTTP chunking.


..early draft.... to be continued 
