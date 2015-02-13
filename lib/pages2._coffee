@__Pages = class Pages

  settings:
    
    #settingName: [canBeMadeAvailableToTheClient, expectedTypes(s), defaultValue]
    
    dataMargin: [true, Number, 3]
    divWrapper: [true, Match.OneOf(String, Boolean), "pagesCont"] #If defined, should be a name of the wrapper's CSS classname
    fields: [true, Object, {}]
    filters: [true, Object, {}]
    itemTemplate: [true, String, "_pagesItemDefault"]
    navShowEdges: [true, Boolean, false] #If true, overrides navShowFirst and navShowLast
    navShowFirst: [true, Boolean, true] #If true, overrides navShowEdges
    navShowLast: [true, Boolean, true] #If true, overrides navShowEdges
    resetOnReload: [true, Boolean, false]
    paginationMargin: [true, Number, 3]
    perPage: [true, Number, 10]
    #requestTimeout: [true, Number, 2]
    route: [true, String, "/page/"]
    router: [true, Match.Optional(String), undefined] #Can be any type. Use only in comparisons. Expects String or Boolean
    routerTemplate: [true, String, "pages"]
    routerLayout: [true, Match.Optional(String), undefined]
    sort: [true, Object, {}]
    
    # Unavailable to the client after initialization
    
    auth: [false, Match.Optional(Function), undefined]
    availableSettings: [false, Object, {}]
    fastRender: [false, Boolean, false]
    homeRoute: [false, Match.OneOf(String, Array, Boolean), "/"]
    infinite: [false, Boolean, false]
    infiniteCont: [false, Match.Optional(Function), undefined]
    infiniteItemsLimit: [false, Match.Optional(Number), undefined]
    infinitePagesLimit: [false, Match.Optional(Number), undefined]
    infiniteTrigger: [false, Number, 1]
    infiniteRateLimit: [false, Number, 1]
    navTemplate: [false, String, "_pagesNavCont"]
    onDeniedSetting: [false, Function, (k, v, e) -> console?.log "Changing #{k} not allowed."]
    pageSizeLimit: [false, Number, 60]
    pageTemplate: [false, String, "_pagesPageCont"]
    rateLimit: [false, Number, 1]
    routeSettings: [false, Match.Optional(Function), undefined]
    table: [false, Match.OneOf(Boolean, Object), false]
    tableItemTemplate: [false, String, "_pagesTableItem"]
    tableTemplate: [false, String, "_pagesTable"]
    templateName: [false, Match.Optional(String), undefined] #Defaults to collection name
  
  # Prototype variables (shared between instances)
  
  _nInstances: 0
  collections: {}
  instances: {}
  
  methods:
    
    "CountPages": (sub) ->
      n = sub.get "nPublishedPages"
      return n  if n?

      n = Math.ceil @Collection.find(
        $and: [
          sub.get("filters"),
          sub.get("realFilters") or {}
        ]
      ).count() / (sub.get "perPage")
      n or 1
    
    "Set": (k, v, sub) ->
      check k, String
      check v, @settings[k][1]
      check sub, Match.Where (sub) ->
        sub.connection?.id?
      cid = sub.connection.id
      return 0  if @valuesEqual(@get(k, cid), v)
      if !@availableSettings[k] or (_.isFunction(@availableSettings[k]) and !@availableSettings[k] v, sub)
        @error 4002, "Changing #{k} not allowed."
      changes = 0
      if v?
        changes = @_set k, v, cid: cid
      else if _.isObject k
        for _k, _v of k
          changes += @_set _k, _v, cid: cid
      changes
    
    "Unsubscribe": ->
      subs = []
      for i, k in @subscriptions
        if i.connection.id is arguments[arguments.length - 1].connection.id
          i.stop()
        else
          subs.push i
      @subscriptions = subs
      true
  
  constructor: (collection, settings = {}) ->
    unless @ instanceof Meteor.Pagination
      throw new Meteor.Error 4000, "The Meteor.Pagination instance has to be initiated with `new`"
    
    # Instance variables
    
    @init = true
    @subscriptions = []
    @userSettings = {}
    @_currentPage = 1

    # Setup

    @setCollection collection
    @set settings, init: true
    @setDefaults()
    @setRouter()
    @[(if Meteor.isServer then "server" else "client") + "Init"]()
    @registerInstance()
    @
    
  error: (code, msg) ->
    msg = code  if !code?
    throw new Meteor.Error code, msg
  
  # Server initialisation
  
  serverInit: ->
    @setMethods()
    self = @
    
    # Remove the per-connection settings when a client disconnects from the server
    
    Meteor.onConnection (connection) =>
      connection.onClose =>
        delete @userSettings[connection.id]
        
    # Publish the collection that we're paginating, taking a page number as a parameter.
        
    Meteor.publish @name, (page) ->
      self.publish.call self, page, @
  
  # Client initialisation
  
  clientInit: ->
    @requested = {}
    @received = {}
    @queue = []
    @setTemplates()
    @countPages()
    $ =>
      @$window = $ window
      if @infinite
        @$infiniteCont = if @infiniteCont then $(@infiniteCont) else @$window
        #@scrollMonitor()
      if @divWrapper
        @$pageCont = $ ".#{@divWrapper}"
    Tracker.autorun =>
      Meteor.userId?()
      @reload()
    @setInfiniteTrigger()  if @infinite
  
  #
  
  reload: ->
    @unsubscribe =>
      @call "CountPages", (e, total) =>
        @sess "totalPages", total
        p = @currentPage()
        p = 1  if @infinite or !p? or @resetOnReload or p > total
        @sess "currentPage", false
        @sess "currentPage", p
  
  unsubscribe: (cb) ->
    @call "Unsubscribe", =>
      delete @initPage
      delete @lastPage
      @requested = {}
      @received = {}
      @queue = []
      cb()  if cb?
  
  setDefaults: ->
    for k, v of @settings
      @[k] ?= v[2]  if v[2]?
  
  syncSettings: (cb) ->
    S = {}
    for k, v of @settings
      if v[0]
        S[k] = @[k]
    @set S, if cb? then {cb: cb.bind(@)} else null
  
  # Creates server-side methods for this pagination *instance* by prefixing them with our unique id
  
  setMethods: ->
    nm = {}
    self = @
    for n, f of @methods
      nm[@getMethodName n] = ((f) ->
        ->
          arg = (k for k, v of arguments)
          arg.push @
          arg.push @
          @get = ((self, k) -> self.get k, @connection.id).bind @, self
          r = f.apply self, arg
          r
      )(f)
      
    Meteor.methods nm
  
  # Get's the server's method name for this pagination instance
  
  getMethodName: (name) ->
    "#{@id}/#{name}"
  
  # Calls this instance's version of a given server method (first argument).
  # If the last argument is a function callback, it's bound to this instance
    
  call: (args...) ->
    check args, Array
    if args.length < 1
      @error 4001, "Method name not provided in a method call."
    args[0] = @getMethodName args[0]
    last = args.length - 1
    if _.isFunction args[last]
      args[last] = args[last].bind @
    Meteor.call.apply @, args
  
  # Sets/gets a session variable for this instance
  
  sess: (k, v) ->
    return  if !Session?
    k = "#{@id}.#{k}"
    if arguments.length is 2
      Session.set k, v
    else
      Session.get k

  # Gets a given setting
  #      
  # When there's a connection id we store this setting on a per-connection basis, otherwise we just
  # set the setting on this pagination instance

  get: (setting, connectionId) ->
    @userSettings[connectionId]?[setting] or @[setting]
  
 # Sets the options for this instnace
    
  set: (k, opts...) ->
    ch = 0
    switch opts.length
      when 0
        # set <object> (set the value of each property in object)
        if _.isObject k
          for _k, _v of k
            ch += @_set _k, _v
      when 1
        if _.isObject k
          # set <object>, callback
          # We wrap the callback and associate with each property of the object being set
          if _.isFunction opts[0]
            opts[0] = cb: opts[0]
          for _k, _v of k
            ch += @_set _k, _v, opts[0]
        else
          # set <name>, <value>
          check k, String
          ch = @_set k, opts[0]
      when 2
         # set <name>, <value>, [<callback fn>]
        if _.isFunction opts[1]
          opts[1] = cb: opts[1]
        ch = @_set k, opts[0], opts[1]
      when 3
        check opts[1], Object
        check opts[2], Function
        opts[2] = cb: opts[2]
        ch = @_set k, opts[1], opts[2]
    if Meteor.isClient and ch
      @reload()
    ch
    
  # Sets a specific option
      
  _set: (k, v, opts = {}) ->
    check k, String
    ch = 0
    
    # Check that we're the server, or that we're being initialised, or that this setting can be changed
    # after initialisation, or that the setting does yet exist on this instance.
    
    if Meteor.isServer or !@[k]? or @settings[k]?[0] or opts.init
    
      # Check the type of the value against the @settings array
      if @settings[k]?[1]? and @settings[k]?[1] isnt true
        check v, @settings[k][1]
      
      # Set the parameter on this instance (client)  
      
      oldV = @get(k, opts?.cid)
      if !@valuesEqual(oldV, v)
        ch = 1
        @[k] = v  if Meteor.isClient 
            
      if Meteor.isClient
        if opts.init
          #When initiating, just set the value without consulting the server
          @[k] = v
        else
          # Change the setting for the corresponding instance on the server.
          # In the callback, set the new value on the client-side unless there's an error.
          @call "Set", k, v, (e, r) ->
            if e
              return @onDeniedSetting.call @, k, v, e
            else
              @[k] = v
            opts.cb? ch
      else
        # When there's a connection id we store this setting on a per-connection basis, otherwise we just
        # set the setting on this pagination instance
        if Meteor.isServer and opts.cid
          if ch
            @userSettings[opts.cid] ?= {}
            @userSettings[opts.cid][k] = v
        else
          @[k] = v
        opts.cb? ch
    else
      @onDeniedSetting.call @, k, v
    ch
    
  valuesEqual: (v1, v2) ->
    EJSON.equals(v1, v2) or (_.isFunction(v1) and _.isFunction(v2) and v1.toString() is v2.toString())
  
  # 
  
  setId: (name) ->
    if @templateName
      name = @templateName
    while name of Pages::instances
      n = name.match /[0-9]+$/
      if n?
        name = name[0 ... name.length - n[0].length] + (parseInt(n) + 1)
      else
        name = name + "2"
    @id = "pages_" + name
    @name = name
  
  #
  
  registerInstance: ->
    Pages::_ninstances++
    Pages::instances[@name] = @
  
  # Set the collection on which this instance operates. Creates a new one if a name is passed in.
  
  setCollection: (collection) ->
    if typeof collection is "object"
      Pages::collections[collection._name] = collection
      @Collection = collection
    else
      try
        @Collection = new Mongo.Collection collection
        Pages::collections[collection] = @Collection
      catch e
        @Collection instanceof Mongo.Collection or @error 4000, "The '#{collection}' collection 
        was created outside of <Meteor.Pagination>. Pass the collection object
        instead of the collection's name to the <Meteor.Pagination> constructor."
    
    @setId @Collection._name
    
    # Create a collection based on the instance's unique id
    
    @PaginatedCollection = new Mongo.Collection @id
  
  linkTo: (page)->
    if Router.current()?.params
      params = Router.current().params
      params.page = page
      Router.routes["#{@name}_page"].path params
  
  setRouter: ->
    if @router is "iron-router"
      if @infinite and @route is "/page/"
        @route = "/from/"
      if @route.indexOf(":page") is -1
        if @route[0] isnt "/"
          @route = "/" + @route
        if @route[@route.length - 1] isnt "/"
          @route += "/"
        pr = @route = "#{@route}:page"
      t = @routerTemplate
      l = @routerLayout ? undefined
      self = @
      init = true
      
      Router.map ->
        @route "#{self.name}_page",
          path: pr
          template: t
          layoutTemplate: l
          onBeforeAction: ->
            page = parseInt @params.page
            if self.infinite
              if self.init
                self.sess "startFrom", page
                self.sess "currentPage", 1
            else
              if self.init
                self.sess "oldPage", page
                self.sess "currentPage", page
              Tracker.nonreactive =>
                self.onNavClick page
<<<<<<< HEAD
            if self.routeSettings?
              self.routeSettings @
            @next()
=======
              @next()               
        
        # Create one or more routes for the home (first) page
              
>>>>>>> 28900c26e62c5d57b4d7b55cac113dc558d431ed
        if self.homeRoute
          if _.isString self.homeRoute
            self.homeRoute = [self.homeRoute]
          for hr, k in self.homeRoute
            @route "#{self.name}_home#{k}",
              path: hr
              template: t
              layoutTemplate: l
              onBeforeAction: ->
                if self.routeSettings?
                  self.routeSettings @
                if self.init
                  self.sess "oldPage", 1
                  self.sess "currentPage", 1
                @next()
                      
      # If using FastRender, set it up for these routes
                
      if Meteor.isServer and @fastRender
        self = @
        FastRender.route pr, (params) ->
          @subscribe self.name, parseInt params.page
        FastRender.route @homeRoute, ->
          @subscribe self.name, 1    
<<<<<<< HEAD
  setPerPage: (cid) ->
    perPage = @get "perPage", cid
    lim = @get "pageSizeLimit", cid
    @set "perPage", (if lim < perPage then lim else perPage), cid: cid
=======
  
  setPerPage: ->
    @perPage = if @pageSizeLimit < @perPage then @pageSizeLimit else @perPage
  
>>>>>>> 28900c26e62c5d57b4d7b55cac113dc558d431ed
  setTemplates: ->
    name = @templateName or @name
    if @table and @itemTemplate is "_pagesItemDefault"
      @itemTemplate = @tableItemTemplate
    
    # Create a set of template prefixed by the unique id of this pagination instance
    # The helper and events are set to those of the base versions of those templates (captured by controllers.coffee)
    
    for i in [@navTemplate, @pageTemplate, @itemTemplate, @tableTemplate]
      tn = @id + i
      Template[tn] = new Blaze.Template "Template.#{tn}", Template[i].renderFunction
      Template[tn].helpers _TemplateHelpers[i]
      Template[tn].events _TemplateEvents[i]
      Template[tn].helpers pagesData: @
      
    # Set our helpers on the main template set for this pagination  
      
    Template[name].helpers
      pagesData: @
      pagesNav: Template[@id + @navTemplate]
      pages: Template[@id + @pageTemplate]
  
  # Get the number of pages from the server
      
  countPages: _.throttle ->
      @call "CountPages", ((e, r) ->
        @sess "totalPages", r
        if @sess("currentPage") > r
          @sess "currentPage", 1
      ).bind(@)
    , 500
    
  publishNone: ->
    @ready()
    return @Collection.find null
  
  # Called from the Meteor.publish call made during init, this Publishes the paginated collection
  #
  # "this" will be the pagination instance
  # "page" is the page number to publish
  # "sub" is the publish handler object which (the "this" object when the function passed to Meteor.publish is called)
  
  publish: (page, sub) ->
    check page, Number
    check sub, Match.Where (s) ->
      s.ready?
    cid = sub.connection.id
    
    # Create get and set functions for this specific connection (the settings will end up in the @userSettings,
    # stored in an object indexed under the collection id)
    
    get = sub.get = ((cid, k) -> @get k, cid).bind(@, cid)
    set = sub.set = ((cid, k, v) -> @set k, v, cid: cid).bind(@, cid)
    
    # If there are already filters set up for this connection id, clear them (is this right?)
    
    delete @userSettings[cid]?.realFilters
    delete @userSettings[cid]?.nPublishedPages
    @setPerPage cid
    perPage = get "perPage"
    skip = (page - 1) * perPage
    skip = 0  if skip < 0
    filters = get "filters"
    options = 
      sort: get "sort"
      fields: get "fields"
      skip: skip
      limit: perPage
    
    # Call the authentication function if it's supplied
    
    if @auth?
      r = @auth.call @, skip, sub
      if !r
        set "nPublishedPages", 0
        return @publishNone()
      else if _.isNumber r
        set "nPublishedPages", r
        return @publishNone()  if page > r
      else if _.isArray(r) and r.length is 2
        if _.isFunction r[0].fetch
          c = r
        else
          filters = r[0]
          options = r[1]
      else if _.isFunction r.fetch
        c = r
    if !EJSON.equals({}, filters) and !EJSON.equals(get("filters"), filters)
      set "realFilters", filters
    
    # Get a cursor to the base collection
    
    c ?= @Collection.find filters, options
    
    init = true
    self = @
    
    # We need to call sub's added callback when a new document is added, however
    # for the purposes of pagination we also need to include the index each document.
    #
    # Furthermore, an added document might increase the index of other documents on this page.
    #
    # We therefore need to use the observe method to handle this.
    
    handle = c.observe
      addedAt: ((sub, doc, at) ->
        try
          doc["_#{@id}_p"] = page
          doc["_#{@id}_i"] = at
          id = doc._id
          delete doc._id
          unless init
            
            # Add to @PaginatedCollection
            
            sub.added(@id, id, doc)
            (@Collection.find get "filters",
              sort: get "sort"
              fields: get "fields"
              skip: skip
              limit: get "perPage"
            ).forEach (o, i) =>
              if i >= at
                sub.changed(@id, o._id, _.object([["_#{@id}_i", i + 1]]))
        catch e
      ).bind @, sub
    
    # For the other cases the more efficient observeChanges will suffice...
      
    handle2 = c.observeChanges
      movedBefore: ((sub, id, before) ->
        ref = false
        (@Collection.find get "filters",
          sort: get "sort"
          fields: get "fields"
          skip: skip
          limit: get "perPage"
        ).forEach (o, i) =>
          if !ref and o._id is before
            ref = true
            at = i
          if ref
            sub.changed(@id, o._id, _.object([["_#{@id}_i", i + 1]]))
          
        sub.changed(@id, id, _.object([["_#{@id}_i", i]]))
      ).bind @, sub
      
      changed: ((sub, id, fields) ->
        try
          sub.changed @id, id, fields
        catch e
      ).bind @, sub
      
      removed: ((sub, id) ->
        try
          sub.removed @id, id
        catch e
      ).bind @, sub
    
    # Add the documents from this query 
    
    n = 0
    c.forEach ((doc, index, cursor) ->
      n++
      doc["_#{@id}_p"] = page
      doc["_#{@id}_i"] = index
      sub.added @id, doc._id, doc
    ).bind @
    
    init = false
    sub.onStop ->
      handle.stop()
      handle2.stop()
    @ready()
    @subscriptions.push sub
    c
  
  # Sets the state of the current page as "loading" (ready = false)  
  
  loading: (p) ->
    if !@fastRender and p is @currentPage()
      @sess "ready", false
  
  now: ->
    (new Date()).getTime()
  
  log: (msg) ->
    console.log "#{@name} #{msg}"
  
  logRequest: (p) ->
    @timeLastRequest = @now()
    @requesting = p
    @requested[p] = 1
  
  logResponse: (p) ->
    delete @requested[p]
    @received[p] = 1
  
  clearQueue: ->
    @queue = []
  
  neighbors: (page) ->
    @n = []
    if @dataMargin is 0
      return @n
    for d in [1 .. @dataMargin]
      np = page + d
      if np <= @sess "totalPages"
        @n.push np
      pp = page - d
      if pp > 0
        @n.push pp
    @n
  
  queueNeighbors: (page) ->
    for p in @neighbors page
      @queue.push p  if !@received[p] and !@requested[p]
  
  paginationNavItem: (label, page, disabled, active = false) ->
    p: label
    n: page
    active: if active then "active" else ""
    disabled: if disabled then "disabled" else ""
  
  paginationNeighbors: ->
    page = @currentPage()
    total = @sess "totalPages"
    from = page - @paginationMargin
    to = page + @paginationMargin
    if from < 1
        to += 1 - from
        from = 1
    if to > total
        from -= to - total
        to = total
    from = 1 if from < 1
    to = total if to > total
    n = []
    if @navShowFirst or @navShowEdges
      n.push @paginationNavItem "«", 1, page == 1
    n.push @paginationNavItem "<", page - 1, page == 1
    for p in [from .. to]
      n.push @paginationNavItem p, p, page > total, p is page
    n.push @paginationNavItem ">", page + 1, page >= total
    if @navShowLast or @navShowEdges
      n.push @paginationNavItem "»", total, page >= total
    for i, k in n
      n[k]['_p'] = @
    n
  
  onNavClick: (n) ->
    if n <= @sess("totalPages") and n > 0
      Deps.nonreactive =>
        cp = @sess "currentPage"
        if @received[cp]
          @sess "oldPage", cp
      @sess "currentPage", n
<<<<<<< HEAD
  scrollTypes: {}
  #  34: 1
  #  33: -1
  #  35: 2
  scroll: (type = 34) ->
    type = @scrollTypes[type] or type
    b = $ document.body
    wh = @$window.height()
    if !@_scrolling
      @_scrolling = true
      b.animate
        scrollTop: b.scrollTop() + wh * type
      , 500, =>
        @_scrolling = false
    false
  scrollMonitor: ->
    st = ost = @$infiniteCont.scrollTop()
    int = 500
    setInterval =>
      st = @$infiniteCont.scrollTop()
      v = Math.abs(ost - st) / int * 1000
      ost = st
    , int
  setInfiniteTrigger: ->
    $ =>
      @$window.on "keydown", (e) =>
        return false  if @blockScrolling
        return @scroll(e.keyCode)  if @scrollTypes[e.keyCode]
      #$(".pagesCont").height($(window).height() * 10)
      ###
      @infiniteCont.scroll =>
        pc = $(".pagesCont")
        lc = $(pc.children()[@perPage * @sess("currentPage") - 1])
        th = lc.offset().top + lc.height()#pc.height() + parseFloat pc.css "marginTop"
        ch = @infiniteCont.height()
        #th = 10 * ch
        h = lc.offset().top + lc.height() - pc.offset().top
        cs = @infiniteCont.scrollTop()
        dh = h - ch
        pt = cs - (dh * cs / (th - ch))
        console.log pt
        #pt = cs
        pc.css
          marginTop: pt
          height: th - pt
      ###
      @$infiniteCont.scroll @infiniteCheck.bind(@)
  infiniteCheck: _.throttle ->
    cp = @sess "currentPage"
    return  if cp >= @sess("totalPages")
    t = @infiniteTrigger
    oh = @$infiniteCont.height()
    if (t >= 1 and cp < @lastVisiblePage() + t) or
    (1 > t > 0 and (@$infiniteCont.innerHeight() + @$infiniteCont.scrollTop()) >= oh * t)
      @blockScrolling = true
      @sess("currentPage", cp + 1)
  , @infiniteRateLimit * 1000
  firstVisibleItem: ->
    firstPixel = @$infiniteCont.scrollTop()
    for k, v of @itemOffsets
      return k - 1  if v > firstPixel
    Number k
  lastVisibleItem: ->
    lastPixel = @$infiniteCont.scrollTop() + @$infiniteCont.height() - 1
    for k, v of @itemOffsets
      return k - 1  if v > lastPixel
    Number k
  lastVisiblePage: ->
    @calcItemOffsets()
    1 + @lastVisibleItem() / @perPage
=======
  
  setInfiniteTrigger: ->
    $(window).scroll (_.throttle ->
      t = @infiniteTrigger
      oh = document.body.offsetHeight
      if t > 1
        l = oh - t
      else if t > 0
        l = oh * t
      else
        return
      if (window.innerHeight + window.scrollY) >= l
        if @lastPage < @sess "totalPages"
          @sess("currentPage", @lastPage + 1)
    , @infiniteRateLimit * 1000
    ).bind @
  
>>>>>>> 28900c26e62c5d57b4d7b55cac113dc558d431ed
  checkQueue: _.throttle ->
    cp = @currentPage()
    neighbors = @neighbors cp
    
    # If we haven't yet received the current page then clear all the other subscriptions and requests
    # and get the current page
    
    if !@received[cp]
      @clearQueue()
      @requestPage cp
      cp = String cp
      for k, v of @requested
        if k isnt cp
          if @subscriptions[k]?
            @subscriptions[k].stop()
            delete @subscriptions[k]
          delete @requested[k]
    
    # If we do have the current page then queue the neighbours
    
    else if @queue.length
      while @queue.length > 0
        i = @queue.shift()
        if i in neighbors
          @requestPage i
          break
  , 500
  
  currentPage: ->
    if Meteor.isClient and @sess("currentPage")?
      @sess "currentPage"
    else
      @_currentPage
  
  isReady: ->
    @sess "ready"
  
  ready: (p) ->
    if p is true or p is @currentPage() and Session?
      @sess "ready", true
  
  checkInitPage: ->
    if @init 
      if @router
        Router.current()?.route?.getName()
        try
          @initPage = parseInt(Router.current().route.params(location.href)?.page) or 1
          @init = false
        catch
          return
      else
        @initPage = 1
        @init = false    
    @sess "oldPage", @initPage
    @sess "currentPage", @initPage
  
  getPage: (page) ->
    if Meteor.isClient
      page = @currentPage()  unless page?
      page = parseInt page
      return  if page is NaN
      total = @sess "totalPages"
<<<<<<< HEAD
      from = (@sess("startFrom") - 1) or 0
      cp = from + @sess "currentPage"
      return @ready true  if total is 0 
=======
      return @ready true  if total is 0
      
      # Request data for the page
      
      if page <= total
        @requestPage page
        @queueNeighbors page
        @checkQueue()
      
      # Return the content of this page 
      #
      # The contents will be updated (as will the page) as data arrives from the server
      
>>>>>>> 28900c26e62c5d57b4d7b55cac113dc558d431ed
      if @infinite
        lim = Infinity
        if @infiniteItemsLimit
          lim = @infiniteItemsLimit
        else if @infinitePagesLimit
          lim = @infinitePagesLimit * @perPage
        query = {}
        idp = "_#{@id}_p"
        if from > 1
          p = Math.floor(from / @perPage)
          skip = from % @perPage
          query[idp] =
            $gt: p
            $lte: p + cp
        else
          query[idp] = $lte: cp
          skip = 0
        c = @PaginatedCollection.find(query,
          fields: @fields
          limit: lim
          skip: skip
          sort: @sort
        )
      else
        c = @PaginatedCollection.find(
          _.object([
            ["_#{@id}_p", page]
          ]),
          fields: @fields
          sort: _.object([
            ["_#{@id}_i", 1]
          ])
        )
        c.observeChanges
          added: =>
            @countPages()
          removed: =>
            @countPages()
<<<<<<< HEAD
      if page <= total
        @requestPage page
        @queueNeighbors page
        @checkQueue()
=======
      
>>>>>>> 28900c26e62c5d57b4d7b55cac113dc558d431ed
      c.fetch()
  
  # Subscribes to the given page
  
  requestPage: (page) ->
    return  if !page or @requested[page] or @received[page]
    @logRequest page
    Meteor.defer ((page) ->
      @subscriptions[page] = Meteor.subscribe @name, page,
        onReady: ((page) ->
          @onPage page
        ).bind @, page
        onError: (e) =>
          @error e.message
    ).bind @, page
  
  # Called when a page has been received
  
  onPage: (page) ->
    @logResponse page
    @ready page
    if @infinite
      @lastPage = page
      if @lastPage < @sess "totalPages"
        @requestPage(@lastPage + 1)
      @infiniteCheck()
    @countPages()
    @checkQueue()

Meteor.Pagination = Pages