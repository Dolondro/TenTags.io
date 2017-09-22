

var userSettings = {};
var userID;
var userFilters = [];

$(function() {
  
  LoadKeybinds();
  LoadUserFilters();
  FilterToggle()
  Recaptcha()
  AddInfoBar();
  HookSubClick();
  $('.post-full-topbar').click(function(e){
    console.log(e.currentTarget)
    $(e.currentTarget).parent().find('.linkImg').toggle()
  })

  $('.post').hover(function(e){
    $(e.target).children('.post-full-bottombar').show();
    //$(e.target).find('.post-filters').show();
  })

  $('.post').focusout(function(e){
    $(e.target).children('.post-full-bottombar').hide();
    //$(e.target).find('.post-filters').hide();
  })

  //$('.settings-menu').focusout(function(){
  //  $('.settings-menu').hide()
  //})
})



function HookSubClick(){
  $('.filterbar-subscribe').click(function(e){
    e.preventDefault();

    var button = $(e.currentTarget)

    var buttonChild = button.children('span')
    if (buttonChild.hasClass('ti-close')){
      buttonChild.removeClass('ti-close')
      buttonChild.addClass('ti-star')
    } else {
      buttonChild.removeClass('ti-star')
      buttonChild.addClass('ti-close')
    }
    var filterID = button.attr('data-filterid')
    console.log(filterID)
    if (filterID != undefined ){
      $.get('/api/filter/'+filterID+'/sub', function(data){
        console.log(data)
      });
    }

  })
}

function LoadUserFilters(){
  var userID = $('#userID').val()
  if (!userID) {
    console.log('couldnt get userID')
    return;
  }

  $.get('/api/user/filters', function(data){
    console.log(data)
    if(data.error == false) {
      userFilters = data.data
    }
  });
}

function AddInfoBar(){
  $('.infobar-title').click(function(e){
    $('.infobar-body').toggle()
    e.preventDefault()
  })

}

function Recaptcha(){
  $('.form-login').focusin(function(){
    $('.form-login > div').show()
  })

  $('.form-login').focusout(function(){
    $('.form-login > div').hide();
  })

  $('.g-recaptcha').prop('disabled',true)
}





function SubmitLogin(){

  console.log('done')
  document.getElementById("register").submit();
}

function FilterToggle(){
  var filterBar = $('.filter-bar')

  var $hamburger = $(".hamburger");
  $hamburger.click(function(e) {
    e.stopPropagation();
    console.log('this')
    $hamburger.toggleClass("is-active");

    var display = filterBar.css('display');
    if (display === 'flex' || display ==='table-cell') {
      filterBar.css('display',"none");
      console.log('hiding filtebar')
    } else {

      if($(window).width() < 481) {
        filterBar.css('display','flex')
        filterBar.focus()
        filterBar.focusout(function(e){
          console.log(e)
          if ($(e.relatedTarget).parents('.filter-bar').length){
            console.log('thisjiuh')
          } else {
            console.log('nope')
            filterBar.hide()
          }
        })


      } else {
        filterBar.css('display',"table-cell");
      }
    }

  });

  $('.toggle-filterstyle').click(function(e){
    $('.filter-styles').toggle()
    e.preventDefault();
  })

}

function Upvote(e) {
  var post = $(':focus')

    e.preventDefault()
  if (post.length) {
    VotePost(post, 'up');
  }
}

function Downvote(e) {
  var post = $(':focus')

  e.preventDefault()
  if (post.length) {
    console.log(2)
    VotePost(post, 'down');
  }
}





function OpenLink(e) {
  if ($(':focus').find(".post-link").length) {
    var url = $(':focus').find(".post-link").attr('href')
    console.log(url)
    window.open(url, '_blank');
    e.preventDefault();
  }
}


function OpenComments(e) {
  if ($(':focus').find(".comment-link").length) {
    var url = document.location.origin+$(':focus').find(".comment-link").attr('href')
    console.log(url)
    window.open(url, '_blank');
    e.preventDefault();
  }

}


function MoveFocus(e) {
  e.preventDefault();
  var thisPost = $(':focus')
  if (!thisPost.hasClass('post')) {
    return
  }
  var nextPost
  if (e.key == 'ArrowUp') {
    nextPost = thisPost.prev()
  } else if (e.key == 'ArrowDown') {
    nextPost = thisPost.next()
  } else {
    console.log(e.key)
  }

  if (nextPost.length) {
    nextPost.focus()
  }
}

function LoadKeybinds(){


  Mousetrap.bind('up', MoveFocus);
  Mousetrap.bind('down', MoveFocus);
  Mousetrap.bind("enter", OpenLink)
  Mousetrap.bind('space', OpenComments);
  Mousetrap.bind("right", Upvote)
  Mousetrap.bind("left", Downvote)

  $('#posts').children().first().focus();

}

var userFilters = {};



function ChangeFocus(value) {

  index = index + value;
  var numChildren = $('#posts').children().length -1
  index = Math.max(index, 0)
  index = Math.min(index, numChildren)
  $('#posts').children().eq(index).focus();
}

function UserHasFilter(filterID){
  var found = null;
  $.each(userFilters, function(k,v){

    if (v.id == filterID) {
      found = true;
      return;
    }

  })
  return found;
}

function UpdateSidebar(filters){
  var filterContainer  = $('.filterbar-results')
  filterContainer.empty()
  $.each(filters.data, function(index,value){


    //filterContainer.append(
    var filterBarElement = `
    <ul class = 'filterbarelement'>
      <a href ='/f/`+value.id+`/sub' class = 'filterbar-subscribe' data-filterid="`+value.id+`"> `
      console.log(UserHasFilter(value.id))
      if (UserHasFilter(value.id) == true) {
        console.log('minus')
        filterBarElement += '<span class="ti-minus"></span>'
      } else {
        console.log('plus')
        filterBarElement += '<span class="ti-plus"></span>'
      }
      filterBarElement +=`
      <a href ='/f/`+value.name+`' class='filterbar-link'>
        <span > `+value.name+`</span>
      </a>
    </ul>`;

    filterContainer.append(filterBarElement);
  })
  HookSubClick()
}

function AddFilterSearch(){

}