
var index = -1
var depth = 0
var hasFocus = false
var currentParent

$(function() {
  $('.filtername').click( function(e) {
    console.log($(this).html())
    $('.filter_' + $(this).html()).toggle()
  })

  $(document).on('click', '.togglefiltercomment', function() {
    $(this).toggleClass('togglefilter-selected');
    var className = '.'+$(this).attr('data-filterID')
    console.log(className);
    $(className).toggle();
  });

})

function ChangeFocus(value) {
  if (index == -1) {
    index = 0
  } else {
    index = index + value;
  }
  var numChildren = currentParent.children(".comment").length -1
  index = Math.max(index, 0)
  index = Math.min(index, numChildren)
  currentParent.children(".comment").eq(index).focus();
}


Mousetrap.bind('tab', function(e) {
  e.preventDefault();
  currentParent = $('#comments').children(".comment").eq(0)
  currentParent.children(".comment").eq(0).focus()

  if (hasFocus == true) {
    hasFocus = false
    Mousetrap.bind('up');
    Mousetrap.bind('down');
    Mousetrap.bind('right');
    Mousetrap.bind('left');
  } else {
    hasFocus = true
    Mousetrap.bind('up', function(e) {
      e.preventDefault();
      ChangeFocus(-1);
    });
    Mousetrap.bind('down', function(e) {
      e.preventDefault();
      ChangeFocus(1);
    });
    Mousetrap.bind('left', function(e) {
      e.preventDefault();
      if (currentParent.parent().children(".comment").length) {
        currentParent = currentParent.parent()
        currentParent.children(".comment").eq(0).focus()
        index = 0
      }
    });
    Mousetrap.bind('right', function(e) {
      e.preventDefault();
      if (currentParent.children(".comment").eq(0).length) {
        currentParent = currentParent.children(".comment").eq(0);
        index = 0
        currentParent.children(".comment").eq(0).focus()
      }
    });
  }
})
