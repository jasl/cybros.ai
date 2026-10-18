module Nexus
  # THE NAME TABLE: the words the kernel assigns an agent member as its
  # handle when the creation names none — a random pick, a numeric suffix
  # on collision (`User::Handle`). Birds, minerals and trees: short,
  # neutral, no brands, no people. Code and not a config file on purpose:
  # the table is the kernel's, not a deployer's knob, so it lives beside
  # the kernel's other vocabularies and is read once at load; a YAML under
  # `config/` would say "edit me" to the wrong reader.
  module AgentHandles
    WORDS = %w[
      robin finch sparrow swift swallow lark thrush starling magpie raven
      crow rook jackdaw heron egret crane stork ibis plover curlew
      sandpiper gull tern puffin gannet cormorant pelican kingfisher hoopoe cuckoo
      nightjar owl kestrel harrier osprey kite buzzard eagle falcon condor
      grouse quail partridge pheasant pigeon dove teal wigeon pintail mallard
      eider goose swan loon grebe coot moorhen bittern oriole tanager
      warbler kinglet nuthatch wagtail pipit bunting siskin linnet redpoll crossbill
      grosbeak waxwing shrike dipper chough avocet godwit dunlin knot sanderling
      turnstone lapwing snipe woodcock skylark blackcap chiffchaff firecrest goldcrest treecreeper
      quartz feldspar mica olivine garnet beryl topaz zircon mainlinel corundum
      tourmaline agate onyx opal flint chert basalt granite gneiss schist
      slate marble shale pumice obsidian gypsum calcite dolomite halite fluorite
      apatite pyrite galena hematite magnetite malachite azurite turquoise cobalt nickel
      copper tin zinc iron silver gold platinum lithium sodium argon
      neon krypton xenon carbon silicon boron sulfur graphite diamond sapphire
      emerald amethyst citrine peridot aquamarine moonstone sunstone kyanite epidote biotite
      augite labradorite rhodonite serpentine talc chalk ochre umber selenite celestine
      oak elm birch beech alder willow poplar aspen maple sycamore
      linden hornbeam chestnut walnut hickory pecan cherry plum pear quince
      medlar hawthorn blackthorn yew juniper cedar cypress pine spruce fir
      larch hemlock redwood sequoia ginkgo magnolia myrtle fig mulberry elder
      spindle dogwood tamarack catalpa sassafras tupelo sweetgum buckeye ironwood cottonwood
      mesquite acacia baobab teak mahogany ebony rosewood sandalwood banyan mangrove
      palm bamboo eucalyptus jacaranda tamarind kauri rimu totara kowhai wattle
    ].freeze

    def self.pick = WORDS.sample
  end
end
