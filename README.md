This is a 1 file package for indexed scroll controller to a flutter ListView.

## Features

A scroll controller lets you scroll to a targeted item in the list. If the item was already
constructed, was scrolled to or was scrolled throught the controller will jump to
~ 1.5 screen size height near the targeted widget and then smoothly scroll to it.

If the item was not constructed, viewed or traversed through, the list will animate
rapidly to the desired item.

## Usage

Firstly we need items and a scrollController. We can define the `items` as `late` and fill them
in `initState`
```dart
late final IndexedScrollController scrollController;
late List<String> items;

@override
void initState() {
  scrollController = IndexedScrollController(scrollDuration: const Duration(milliseconds: 300));
  items = List.generate(1000, (index) => lorem(paragraphs: 1, words: 5 + randomizer.nextInt(25)));
  super.initState();
}
```

Then create a `ListView` and assign our `scrollController` to it.
Use the scrollController `watch` method or wrap your items in `IndexedScrollItem` widget.
```dart
ListView.builder(
    controller: scrollController,
    itemCount: items.length,
    itemBuilder: (context, index) {
      return scrollController.watch(
        index: index,
        child: Container(
          color: Color(randomizer.nextInt(0x00ffffff)).withAlpha(30),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Text('$index --> ${items[index]}'),
        ),
      );
    },
);
```

For scrolling to an arbitrary item, use the `scrollTo` method.
```dart
scrollController.scrollTo(
    scrollToIndex,
    duration: const Duration(milliseconds: 300),
    curve: Curves.linear,
);
```

## Additional information
The `IndexedScrollController` implements a regular `ScrollController` with an internal field delegating and
preserving all it's functions for compatibility purposes.

You can use example for more info.